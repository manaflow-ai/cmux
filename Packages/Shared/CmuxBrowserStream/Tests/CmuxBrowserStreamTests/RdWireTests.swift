import CmuxBrowserStream
import Foundation
import Testing

@Suite("cmux.rd/1 wire (vectors shared with cmux-rd-proto)")
struct RdWireTests {
    @Test func headerGoldenVector() throws {
        // cmux-rd-proto tests/wire.rs header_golden_vector.
        let header = RdDatagramHeader(flags: .keyframe, kind: .video, stream: 2, frame: 0x0102_0304, index: 1, count: 3,
                                      fecCount: 1, transportSeq: 0xbeef)
        let bytes = header.datagram(payload: Data("payload".utf8))
        #expect([UInt8](bytes.prefix(16)) == [0x11, 0x01, 0x02, 0x00, 0x04, 0x03, 0x02, 0x01, 0x01, 0x00, 0x03, 0x00, 0x01, 0x00,
                                               0xef, 0xbe])
        let (decoded, payload) = try RdDatagramHeader.decode(bytes)
        #expect(decoded == header)
        #expect(payload == Data("payload".utf8))
    }

    @Test func headerRejectsBadShardsAndVersions() {
        #expect(throws: RdWireError.self) { try RdDatagramHeader.decode(Data([0x11, 0x01])) }
        var bad = RdDatagramHeader(kind: .video, frame: 1, index: 3, count: 3).datagram(payload: Data())
        #expect(throws: RdWireError.self) { try RdDatagramHeader.decode(bad) }
        bad = RdDatagramHeader(kind: .video, frame: 1, index: 0, count: 1).datagram(payload: Data())
        bad[0] = 0x21
        #expect(throws: RdWireError.self) { try RdDatagramHeader.decode(bad) }
    }

    @Test func frameBodyIgnoresPadding() throws {
        let body = RdFrameBody(captureMicros: 77, refFrame: RdFrameBody.refNone, accessUnit: Data([1, 2, 3]))
        var bytes = body.encoded
        #expect(bytes.count == 19)
        bytes.append(Data(count: 9))
        #expect(try RdFrameBody(decoding: bytes) == body)
    }

    @Test func feedbackRoundTrips() throws {
        let feedback = RdFeedback(ackedFrame: 9, decodeMicros: 1200, needRecovery: true,
                                  arrivals: [RdArrival(transportSeq: 4, arrivalMicros: 99)],
                                  nacks: [RdNack(frame: 10, indexes: [0, 2])])
        #expect(try RdFeedback(decoding: feedback.encoded) == feedback)
        #expect(throws: RdWireError.self) { try RdFeedback(decoding: feedback.encoded + Data([0])) }
    }

    @Test func inputPacketRoundTripsEveryEventKind() throws {
        let packet = RdInputPacket(firstSeq: 41, events: [
            .key(usage: 0x0007_0004, down: true), .pointer(x: -3, y: 9), .button(button: 1, down: false),
            .scroll(dx: 0, dy: -250, precise: true), .text("日本"), .service(mustDeliver: true, bytes: Data("{}".utf8)),
        ])
        #expect(try RdInputPacket(decoding: try packet.encoded()) == packet)
    }

    @Test func serviceBytesAboveOnePacketAreRefused() {
        let event = RdInputEvent.service(mustDeliver: true, bytes: Data(count: RdInputEvent.maxServiceBytes + 1))
        #expect(throws: RdWireError.self) { try RdInputPacket(firstSeq: 1, events: [event]).encoded() }
    }

    @Test func inputAckIsOneU32() throws {
        #expect(RdInputAck(appliedSeq: 0x0102_0304).encoded == Data([4, 3, 2, 1]))
        #expect(try RdInputAck(decoding: Data([7, 0, 0, 0])).appliedSeq == 7)
    }
}
