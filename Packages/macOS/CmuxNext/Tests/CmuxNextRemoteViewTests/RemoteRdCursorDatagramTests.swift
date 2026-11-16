import CoreGraphics
import Foundation
import Testing
@testable import CmuxNextRemoteView

@Suite struct RemoteRdCursorDatagramTests {
    /// A `CursorPos` datagram as cmux-rd-proto encodes it (header, then seq, x, y, visible).
    private func datagram(kind: UInt8 = 6, seq: UInt32, x: UInt32, y: UInt32, visible: UInt8) -> Data {
        var bytes: [UInt8] = [0x10, kind] + [UInt8](repeating: 0, count: 14)
        for value in [seq, x, y] {
            bytes += [UInt8(value & 0xff), UInt8(value >> 8 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 24)]
        }
        bytes.append(visible)
        return Data(bytes)
    }

    @Test func parsesTheHostPointerInStreamPixels() throws {
        let cursor = try #require(RemoteRdCursorDatagram(datagram(seq: 9, x: 1921, y: 70_000, visible: 1)))
        #expect(cursor.seq == 9)
        #expect(cursor.state == RemoteCursorState(position: CGPoint(x: 1921, y: 70_000), visible: true))
        #expect(RemoteRdCursorDatagram(datagram(seq: 1, x: 0, y: 0, visible: 0))?.state.visible == false)
    }

    @Test func refusesOtherKindsAndMalformedPayloads() {
        // An InputAck is not a cursor; a bad visible byte or a short payload is refused.
        #expect(RemoteRdCursorDatagram(datagram(kind: 5, seq: 1, x: 0, y: 0, visible: 1)) == nil)
        #expect(RemoteRdCursorDatagram(datagram(seq: 1, x: 0, y: 0, visible: 2)) == nil)
        #expect(RemoteRdCursorDatagram(datagram(seq: 1, x: 0, y: 0, visible: 1).dropLast()) == nil)
    }

    @Test func latestWinsAcrossReorderAndWrap() throws {
        let five = try #require(RemoteRdCursorDatagram(datagram(seq: 5, x: 0, y: 0, visible: 1)))
        #expect(five.isNewer(than: nil))
        #expect(five.isNewer(than: 4))
        #expect(!five.isNewer(than: 5))
        #expect(!five.isNewer(than: 6))
        let wrapped = try #require(RemoteRdCursorDatagram(datagram(seq: 1, x: 0, y: 0, visible: 1)))
        #expect(wrapped.isNewer(than: UInt32.max))
    }
}
