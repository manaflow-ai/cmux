@testable import CmuxMobileSSH
import Foundation
import Testing

/// SFTPWriter's integers are big-endian on the wire (draft-ietf-secsh-filexfer-02,
/// section 3), written without a pointer to the value, and SFTPReader reads them back.
@Suite struct SFTPWireIntegerTests {
    @Test func uint32IsMostSignificantByteFirst() {
        var writer = SFTPWriter()
        writer.uint32(0x0102_0304)
        #expect([UInt8](writer.body) == [0x01, 0x02, 0x03, 0x04])
    }

    @Test func uint64IsMostSignificantByteFirst() {
        var writer = SFTPWriter()
        writer.uint64(0x0102_0304_0506_0708)
        #expect([UInt8](writer.body) == [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
    }

    @Test(arguments: [UInt64.zero, 1, 0xFF, 0x8000_0000_0000_0000, .max])
    func integersRoundTripThroughTheReader(value: UInt64) throws {
        var writer = SFTPWriter()
        writer.uint32(UInt32(truncatingIfNeeded: value))
        writer.uint64(value)
        var reader = SFTPReader(writer.body)
        #expect(try reader.uint32() == UInt32(truncatingIfNeeded: value))
        #expect(try reader.uint64() == value)
    }

    @Test func packetLengthCountsTheTypeByte() {
        var writer = SFTPWriter()
        writer.byte(7)
        let packet = writer.packet(type: .open)
        #expect([UInt8](packet.prefix(4)) == [0, 0, 0, 2])
        #expect(packet.count == 6)
    }
}
