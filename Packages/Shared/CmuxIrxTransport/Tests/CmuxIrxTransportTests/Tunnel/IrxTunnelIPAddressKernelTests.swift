import Darwin
import Foundation
import Testing

@testable import CmuxIrxTransport

/// The tunnel's address conversions without pointer views:
/// kernel structs to bytes, bytes to text, and the frame length prefix.
@Suite("tunnel address conversions")
struct IrxTunnelIPAddressKernelTests {
    @Test("an in_addr becomes its network-order bytes")
    func inAddrBytes() {
        let address = in_addr(s_addr: UInt32(0xC000_0201).bigEndian)
        #expect(IrxTunnelIPAddress(kernel: address) == .v4([192, 0, 2, 1]))
    }

    @Test("an in6_addr becomes its sixteen bytes")
    func in6AddrBytes() {
        #expect(IrxTunnelIPAddress(kernel: in6addr_loopback) == .loopbackV6)
        #expect(IrxTunnelIPAddress(kernel: in6addr_any) == .v6(Array(repeating: 0, count: 16)))
    }

    @Test("text parses back to the same address")
    func textRoundTrip() throws {
        for literal in ["192.0.2.1", "10.0.0.255", "2001:db8::1", "::ffff:10.0.0.1", "fd00:ec2::254"] {
            let address = try #require(IrxTunnelIPAddress(literal))
            #expect(IrxTunnelIPAddress(address.text) == address)
        }
        #expect(IrxTunnelIPAddress("[::1]")?.text == "::1")
    }

    #if os(macOS)
    @Test("a case built from the wrong byte count stops the process, never prints a wrong target")
    func malformedCaseTraps() async {
        await #expect(processExitsWith: .failure) { _ = IrxTunnelIPAddress.v4([1, 2, 3, 4, 5]).text }
        await #expect(processExitsWith: .failure) { _ = IrxTunnelIPAddress.v4([10, 0]).text }
        await #expect(processExitsWith: .failure) { _ = IrxTunnelIPAddress.v6([]).text }
    }
    #endif

    @Test("strict parsing still refuses shorthand IPv4 and scoped IPv6")
    func strictParsing() {
        #expect(IrxTunnelIPAddress("127.1") == nil)
        #expect(IrxTunnelIPAddress("0x7f.0.0.1") == nil)
        #expect(IrxTunnelIPAddress("fe80::1%en0") == nil)
    }

    @Test("resolving a numeric host returns that address")
    func resolveNumericHost() async {
        let addresses = await IrxTunnelNetworkConnector().resolve(host: "127.0.0.1")
        #expect(addresses.contains(.v4([127, 0, 0, 1])))
    }

    @Test("the frame length prefix is four bytes big-endian")
    func frameLengthPrefix() throws {
        struct Message: Codable { let text: String }
        let encoded = try IrxFrameCodec().encode(Message(text: String(repeating: "x", count: 300)))
        let body = encoded.dropFirst(4)
        let prefix = Array(encoded.prefix(4))
        let length = prefix.reduce(0) { ($0 << 8) | Int($1) }
        #expect(length == body.count)
        #expect(prefix[0] == 0 && prefix[1] == 0)
    }
}
