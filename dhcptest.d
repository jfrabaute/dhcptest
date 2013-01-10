module dhcptest;

import core.thread;

import std.algorithm;
import std.array;
import std.conv;
import std.random;
import std.stdio;
import std.string;
import std.socket;

version(Windows)
    import std.c.windows.winsock;

/// Header (part up to the option fields) of a DHCP packet, as on wire.
align(1)
struct DHCPHeader
{
align(1):
	/// Message op code / message type. 1 = BOOTREQUEST, 2 = BOOTREPLY
	ubyte op;

	/// Hardware address type, see ARP section in "Assigned Numbers" RFC; e.g., '1' = 10mb ethernet.
	ubyte htype;

	/// Hardware address length (e.g.  '6' for 10mb ethernet).
	ubyte hlen;

	/// Client sets to zero, optionally used by relay agents when booting via a relay agent.
	ubyte hops;

	/// Transaction ID, a random number chosen by the client, used by the client and server to associate messages and responses between a client and a server.
	uint xid;

	/// Filled in by client, seconds elapsed since client began address acquisition or renewal process.
	ushort secs;

	/// Flags. (Only the BROADCAST flag is defined.)
	ushort flags;

	/// Client IP address; only filled in if client is in BOUND, RENEW or REBINDING state and can respond to ARP requests.
	uint ciaddr;

	/// 'your' (client) IP address.
	uint yiaddr;

	/// IP address of next server to use in bootstrap; returned in DHCPOFFER, DHCPACK by server.
	uint siaddr;

	/// Relay agent IP address, used in booting via a relay agent.
	uint giaddr;

	/// Client hardware address.
	ubyte[16] chaddr;

	/// Optional server host name, null terminated string.
	char[64] sname = 0;

	/// Boot file name, null terminated string; "generic" name or null in DHCPDISCOVER, fully qualified directory-path name in DHCPOFFER.
	char[128] file = 0;

	/// Optional parameters field.  See the options documents for a list of defined options.
	ubyte[0] options;

	static assert(DHCPHeader.sizeof == 236);
}

/*
35 01 02 
0F 17 68 6F 6D 65 2E 74 68 65 63 79 62 65 72 73 68 61 64 6F 77 2E 6E 65 74 
01 04 FF FF FF 00 
06 04 C0 A8 00 01 
03 04 C0 A8 00 01 
05 04 C0 A8 00 01 
36 04 C0 A8 00 01 
33 04 00 00 8C A0 
FF
*/

struct DHCPOption
{
	ubyte type;
	ubyte[] data;
}

struct DHCPPacket
{
	DHCPHeader header;
	DHCPOption[] options;
}

enum DHCPOptionType : ubyte
{
	subnetMask = 1,
	timeOffset = 2,
	router = 3,
	timeServer = 4,
	nameServer = 5,
	domainNameServer = 6,
	domainName = 15,
	leaseTime = 51,
	netbiosNodeType = 46,
	dhcpMessageType = 53,
	serverIdentifier = 54,
	renewalTime = 58,
	rebindingTime = 59,
}

enum DHCPMessageType : ubyte
{
	discover = 1,
	offer,
	request,
	decline,
	ack,
	nak,
	release,
	inform
}

enum NETBIOSNodeType : ubyte
{
	bNode = 1,
	pNode,
	mMode,
	hNode
}

DHCPPacket parsePacket(ubyte[] data)
{
	DHCPPacket result;

	enforce(data.length > DHCPHeader.sizeof + 4, "DHCP packet too small");
	result.header = *cast(DHCPHeader*)data.ptr;
	data = data[DHCPHeader.sizeof..$];

	enforce(data[0..4] == [99, 130, 83, 99], "Absent DHCP option magic cookie");
	data = data[4..$];

	ubyte readByte()
	{
		enforce(data.length, "Unexpected end of packet");
		ubyte result = data[0];
		data = data[1..$];
		return result;
	}

	while (true)
	{
		auto optionType = readByte();
		if (optionType==0) // pad option
			continue;
		if (optionType==255) // end option
			break;

		auto len = readByte();
		DHCPOption option;
		option.type = optionType;
		foreach (n; 0..len)
			option.data ~= readByte();
		result.options ~= option;
	}

	return result;
}

ubyte[] serializePacket(DHCPPacket packet)
{
	ubyte[] data;
	data ~= cast(ubyte[])((&packet.header)[0..1]);
	data ~= [99, 130, 83, 99];
	foreach (option; packet.options)
	{
		data ~= option.type;
		data ~= to!ubyte(option.data.length);
		data ~= option.data;
	}
	data ~= 255;
	return data;
}

string ip(uint addr) { return format("%(%d.%)", cast(ubyte[])((&addr)[0..1])); }

void printPacket(DHCPPacket packet)
{
	auto opNames = [1:"BOOTREQUEST",2:"BOOTREPLY"];
	writefln("  op=%s chaddr=%(%02X:%) hops=%d xid=%08X secs=%d flags=%04X\n  ciaddr=%s yiaddr=%s siaddr=%s giaddr=%s sname=%s file=%s",
		opNames.get(packet.header.op, text(packet.header.op)),
		packet.header.chaddr[0..packet.header.hlen],
		packet.header.hops,
		packet.header.xid,
		ntohs(packet.header.secs),
		ntohs(packet.header.flags),
		ip(packet.header.ciaddr),
		ip(packet.header.yiaddr),
		ip(packet.header.siaddr),
		ip(packet.header.giaddr),
		to!string(packet.header.sname.ptr),
		to!string(packet.header.file.ptr),
	);

	writefln("  %d options:", packet.options.length);
	foreach (option; packet.options)
	{
		auto type = cast(DHCPOptionType)option.type;
		writef("    %s: ", type);
		switch (type)
		{
			case DHCPOptionType.dhcpMessageType:
				enforce(option.data.length==1, "Bad dhcpMessageType data length");
				writeln(cast(DHCPMessageType)option.data[0]);
				break;
			case DHCPOptionType.netbiosNodeType:
				enforce(option.data.length==1, "Bad netbiosNodeType data length");
				writeln(cast(NETBIOSNodeType)option.data[0]);
				break;
			case DHCPOptionType.subnetMask:
			case DHCPOptionType.router:
			case DHCPOptionType.timeServer:
			case DHCPOptionType.nameServer:
			case DHCPOptionType.domainNameServer:
			case DHCPOptionType.serverIdentifier:
				enforce(option.data.length % 4 == 0, "Bad IP option data length");
				writefln("%(%s, %)", map!ip(cast(uint[])option.data).array());
				break;
			case DHCPOptionType.domainName:
				writeln(cast(string)option.data);
				break;
			case DHCPOptionType.timeOffset:
			case DHCPOptionType.leaseTime:
			case DHCPOptionType.renewalTime:
			case DHCPOptionType.rebindingTime:
				enforce(option.data.length % 4 == 0, "Bad integer option data length");
				writefln("%(%d, %)", map!ntohl(cast(uint[])option.data).array());
				break;
			default:
				writefln("%(%02X %)", option.data);
		}
	}
}

enum SERVER_PORT = 67;
enum CLIENT_PORT = 68;

__gshared UdpSocket socket;

void listenThread()
{
	try
	{
		static ubyte[0x10000] buf;
		ptrdiff_t received;
		Address address;
		while ((received = socket.receiveFrom(buf[], address)) > 0)
		{
			auto receivedData = buf[0..received].dup;
			try
			{
				auto packet = parsePacket(receivedData);
				writefln("Received packet from %s:", address);
				printPacket(packet);
			}
			catch (Exception e)
				writefln("Error while parsing packet [%(%02X %)]: %s", receivedData, e.toString());
		}

		throw new Exception(format("socket.receiveFrom returned %d.", received));
	}
	catch (Exception e)
	{
		writeln("Error on listening thread:");
		writeln(e.toString());
	}
}

void sendPacket()
{
	DHCPPacket packet;
	packet.header.op = 1; // BOOTREQUEST
	packet.header.htype = 1;
	packet.header.hlen = 6;
	packet.header.hops = 0;
	packet.header.xid = uniform!uint();
	packet.header.flags = htons(0x8000); // Set BROADCAST flag - required to be able to receive a reply to an imaginary hardware address
	foreach (ref b; packet.header.chaddr[0..packet.header.hlen])
		b = uniform!ubyte();
	packet.options ~= DHCPOption(DHCPOptionType.dhcpMessageType, [DHCPMessageType.discover]);
	writefln("Sending packet:");
	printPacket(packet);
	socket.sendTo(serializePacket(packet), new InternetAddress("255.255.255.255", SERVER_PORT));
}

void main()
{
	socket = new UdpSocket();
	socket.setOption(SocketOptionLevel.SOCKET, SocketOption.BROADCAST, 1);
	try
	{
		socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
		socket.bind(getAddress("0.0.0.0", CLIENT_PORT)[0]);
		writefln("Listening for DHCP replies on port %d.", CLIENT_PORT);
	}
	catch (Exception e)
	{
		writeln("Error while attempting to bind socket:");
		writeln(e);
		writeln("Replies will not be visible. Use a packet capture tool to see replies,\nor try re-running the program with more permissions.");
	}

	(new Thread(&listenThread)).start();

	writeln("Type \"d\" to broadcast a DHCP discover packet.");
	while (true)
	{
		auto line = readln().strip().split();
		if (!line.length)
		{
			writeln("Enter a command.");
			continue;
		}

		switch (line[0].toLower())
		{
			case "d":
			case "discover":
				sendPacket();
				break;
			default:
				writeln("Unrecognized command.");
		}
	}
}