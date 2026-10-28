import Foundation
import Security
import Testing
@testable import CmuxIrohTransport

/// The encoders and parsers that used to take pointer views:
/// network byte order without `withUnsafeBytes`, IP text through the one
/// `inet_pton`/`inet_ntop` owner, randomness through one `SecRandomCopyBytes` call.
@Suite
struct CmxIrohPointerFreeEncodingTests {
    @Test
    func appendBigEndianWritesMostSignificantByteFirst() {
        var data = Data()
        data.appendBigEndian(UInt8(0xAB))
        data.appendBigEndian(UInt16(0x0102))
        data.appendBigEndian(UInt32(0x0304_0506))
        data.appendBigEndian(UInt64(0x0708_090A_0B0C_0D0E))
        #expect(Array(data) == [0xAB, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E])
    }

    @Test
    func appendBigEndianRoundTripsThroughWireByteReader() {
        let values: [UInt64] = [0, 1, 0xFF, 0x0100, .max, 0x8000_0000_0000_0000]
        var data = Data()
        for value in values { data.appendBigEndian(value) }
        var reader = WireByteReader(data)
        for value in values { #expect(reader.bigEndian(UInt64.self) == value) }
        #expect(reader.remainingCount == 0)
    }

    @Test
    func admissionCodeIsBigEndianInTheFrame() {
        let frame = CmxIrohAdmissionAckCodec().encodeFrame(.denied(code: 0x1234))
        #expect(Array(frame.suffix(2)) == [0x12, 0x34])
    }

    @Test
    func ipLiteralParsesNetworkOrderBytes() throws {
        let ipv4 = try #require(CmxIrohIPLiteral("192.168.1.20", family: .ipv4))
        #expect(ipv4.bytes == [192, 168, 1, 20])
        #expect(ipv4.canonicalText == "192.168.1.20")

        let ipv6 = try #require(CmxIrohIPLiteral("FE80::1", family: .ipv6))
        #expect(ipv6.bytes == [0xFE, 0x80] + Array(repeating: 0, count: 13) + [1])
        #expect(ipv6.canonicalText?.lowercased() == "fe80::1")

        let mapped = try #require(CmxIrohIPLiteral("::ffff:10.0.0.1", family: .ipv6))
        #expect(mapped.bytes == Array(repeating: 0, count: 10) + [0xFF, 0xFF, 10, 0, 0, 1])
    }

    @Test(arguments: ["127.1", "0x7f.0.0.1", "10.0.0.256", "", "::1", "host.local"])
    func ipLiteralRefusesNonDottedQuadIPv4(_ text: String) {
        #expect(CmxIrohIPLiteral(text, family: .ipv4) == nil)
    }

    @Test(arguments: ["fe80::1%en0", "10.0.0.1", "::g", "1::2::3", ""])
    func ipLiteralRefusesNonStandardIPv6(_ text: String) {
        #expect(CmxIrohIPLiteral(text, family: .ipv6) == nil)
    }

    @Test
    func lanSocketAddressKeepsCanonicalBytes() throws {
        let ipv4 = try CmxIrohLANSocketAddress("192.168.1.20:4433")
        #expect(ipv4.addressBytes == [192, 168, 1, 20])
        let ipv6 = try CmxIrohLANSocketAddress("[fd00::5]:4433")
        #expect(ipv6.addressBytes == [0xFD] + Array(repeating: 0, count: 14) + [5])
        #expect(throws: CmxIrohLANDiscoveryError.self) { try CmxIrohLANSocketAddress("[FD00::5]:4433") }
    }

    @Test
    func interfaceMaskComesFromTheLiteralParser() throws {
        let interface = try CmxIrohLANInterfaceAddress(
            interfaceIndex: 4,
            ipAddress: "192.168.1.20",
            netmask: "255.255.255.0"
        )
        #expect(interface.netmaskBytes == [255, 255, 255, 0])
        #expect(interface.contains(try CmxIrohLANSocketAddress("192.168.1.77:4433")))
        #expect(!interface.contains(try CmxIrohLANSocketAddress("192.168.2.77:4433")))
    }

    @Test
    func bindAddressAcceptsOnlyNumericLiterals() throws {
        #expect(try CmxIrohBindAddress(ipAddress: "10.0.0.1", port: 49_152).socketAddress == "10.0.0.1:49152")
        #expect(try CmxIrohBindAddress(ipAddress: "fd00::1", port: 49_152).socketAddress == "[fd00::1]:49152")
        #expect(throws: CmxIrohBindAddressError.self) { try CmxIrohBindAddress(ipAddress: "10.1", port: 49_152) }
    }

    @Test
    func secRandomBytesFillsTheRequestedCount() {
        let first = CmxIrohSystemRandomByteGenerator.secRandomBytes(count: 32)
        let second = CmxIrohSystemRandomByteGenerator.secRandomBytes(count: 32)
        #expect(first.status == errSecSuccess)
        #expect(first.bytes.count == 32)
        #expect(second.bytes.count == 32)
        #expect(first.bytes != second.bytes)
    }
}
