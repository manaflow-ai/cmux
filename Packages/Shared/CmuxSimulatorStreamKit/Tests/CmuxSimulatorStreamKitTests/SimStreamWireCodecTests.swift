import Foundation
import Testing

@testable import CmuxSimulatorStreamKit

@Suite
struct SimStreamWireCodecTests {
    @Test
    func allMessagesRoundTrip() throws {
        let messages: [SimStreamMessage] = [
            .start(
                SimStreamStartRequest(
                    epoch: 42,
                    maximumLongSidePixels: 1600,
                    codecPreferences: [.hevc, .h264]
                )),
            .config(
                SimStreamConfig(
                    codec: .hevc,
                    pixelWidth: 1179,
                    pixelHeight: 2556,
                    displayScale: 3.0,
                    orientation: .portrait,
                    parameterSets: [Data([0x40, 0x01]), Data([0x42, 0x01]), Data([0x44, 0x01])],
                    nalUnitHeaderLength: 4
                )),
            .frame(
                SimStreamFrame(
                    sequence: 7,
                    flags: [.keyframe],
                    presentationMicroseconds: 123_456_789,
                    payload: Data(repeating: 0xAB, count: 1024)
                )),
            .ack(SimStreamAck(sequence: 7, receiptMicroseconds: 99)),
            .input(
                SimStreamInputBatch(
                    sequence: 3,
                    events: [
                        .touch(
                            phase: .began, pointerID: 0, x: 0.25, y: 0.75,
                            timestampMicroseconds: 1000),
                        .touch(
                            phase: .moved, pointerID: 0, x: 0.30, y: 0.70,
                            timestampMicroseconds: 1016),
                        .touch(
                            phase: .ended, pointerID: 0, x: 0.30, y: 0.70,
                            timestampMicroseconds: 1032),
                        .text("héllo wörld 🚀"),
                        .key(usage: 40, isDown: true),
                        .key(usage: 40, isDown: false),
                        .button(.home),
                    ]
                )),
            .keyframeRequest,
            .stop,
            .state(SimStreamStateUpdate(status: .deviceUnavailable, detail: "sim shut down")),
        ]
        for message in messages {
            let encoded = SimStreamWireCodec.encode(message)
            let decoded = try SimStreamWireCodec.decode(encoded)
            #expect(decoded == message)
        }
    }

    @Test
    func framedStreamReassemblesAcrossArbitrarySplits() throws {
        let messages: [SimStreamMessage] = [
            .keyframeRequest,
            .frame(
                SimStreamFrame(
                    sequence: 1, flags: [], presentationMicroseconds: 5,
                    payload: Data(repeating: 0x11, count: 300))),
            .ack(SimStreamAck(sequence: 1, receiptMicroseconds: 10)),
        ]
        var wire = Data()
        for message in messages {
            wire.append(SimStreamWireCodec.encodeFramed(message))
        }

        // Feed the concatenated bytes in pathological chunk sizes.
        for chunkSize in [1, 2, 3, 7, 64, wire.count] {
            var accumulator = SimStreamFrameAccumulator()
            var decoded: [SimStreamMessage] = []
            var offset = 0
            while offset < wire.count {
                let end = min(offset + chunkSize, wire.count)
                accumulator.append(wire.subdata(in: offset..<end))
                offset = end
                while let body = try accumulator.nextMessageBody() {
                    decoded.append(try SimStreamWireCodec.decode(body))
                }
            }
            #expect(decoded == messages, "chunk size \(chunkSize)")
        }
    }

    @Test
    func truncatedMessagesThrow() {
        let encoded = SimStreamWireCodec.encode(
            .frame(
                SimStreamFrame(
                    sequence: 1, flags: [.keyframe], presentationMicroseconds: 2,
                    payload: Data(repeating: 0xCD, count: 64))))
        for cut in [0, 1, 8, encoded.count - 1] {
            let truncated = encoded.prefix(cut)
            #expect(throws: (any Error).self) {
                _ = try SimStreamWireCodec.decode(Data(truncated))
            }
        }
    }

    @Test
    func trailingBytesAreRejected() {
        var corrupted = SimStreamWireCodec.encode(.stop)
        corrupted.append(0xFF)
        #expect(throws: SimStreamWireError.trailingBytes(count: 1)) {
            _ = try SimStreamWireCodec.decode(corrupted)
        }
    }

    @Test
    func unknownMessageTypeThrows() {
        #expect(throws: SimStreamWireError.unknownMessageType(0x7F)) {
            _ = try SimStreamWireCodec.decode(Data([0x7F]))
        }
    }

    @Test
    func unknownCodecPreferenceIsSkippedNotFatal() throws {
        // A future viewer may know codecs this host doesn't; start must
        // still parse so the host can pick from the ones it understands.
        var start = SimStreamWireCodec.encode(
            .start(
                SimStreamStartRequest(
                    epoch: 1, maximumLongSidePixels: 1200, codecPreferences: [.hevc])))
        // Rewrite codec count to 2 and append an unknown codec byte.
        start[start.count - 2] = 2
        start.append(0x77)
        let decoded = try SimStreamWireCodec.decode(start)
        guard case .start(let request) = decoded else {
            Issue.record("expected start")
            return
        }
        #expect(request.codecPreferences == [.hevc])
    }

    @Test
    func oversizedFrameDeclarationFailsFast() {
        var accumulator = SimStreamFrameAccumulator()
        var header = Data()
        withUnsafeBytes(of: UInt32(100_000_000).bigEndian) { header.append(contentsOf: $0) }
        accumulator.append(header)
        #expect(throws: SimStreamWireError.messageTooLarge(byteCount: 100_000_000)) {
            _ = try accumulator.nextMessageBody()
        }
    }
}
