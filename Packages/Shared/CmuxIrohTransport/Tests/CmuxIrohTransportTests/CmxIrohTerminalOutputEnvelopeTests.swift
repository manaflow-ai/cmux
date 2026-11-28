import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohTerminalOutputEnvelopeTests {
    @Test
    func fragmentedReplayAndLiveChunksRoundTripWithExactSequences() throws {
        let replay = try CmxIrohTerminalOutputEnvelope(
            kind: .replay,
            retainedBaseSequence: 40,
            sequence: 42,
            currentSequence: 45,
            payload: Data("abc".utf8)
        )
        let chunk = try CmxIrohTerminalOutputEnvelope(
            kind: .chunk,
            retainedBaseSequence: 45,
            sequence: 45,
            currentSequence: 48,
            payload: Data("def".utf8)
        )
        let codec = CmxIrohTerminalOutputEnvelopeCodec()
        let bytes = codec.encode(replay) + codec.encode(chunk)
        var decoder = CmxIrohTerminalOutputEnvelopeDecoder()
        var decoded: [CmxIrohTerminalOutputEnvelope] = []

        for byte in bytes {
            decoded.append(contentsOf: try decoder.append(Data([byte])))
        }

        #expect(decoded == [replay, chunk])
        #expect(!decoder.hasBufferedBytes)
    }

    @Test
    func sequenceAndPayloadMismatchIsRejectedBeforeEncoding() {
        #expect(throws: CmxIrohTerminalOutputEnvelope.ValidationError.invalidSequenceRange) {
            try CmxIrohTerminalOutputEnvelope(
                kind: .chunk,
                retainedBaseSequence: 11,
                sequence: 10,
                currentSequence: 11,
                payload: Data([1])
            )
        }
        #expect(throws: CmxIrohTerminalOutputEnvelope.ValidationError.payloadLengthMismatch(
            expected: 2,
            actual: 1
        )) {
            try CmxIrohTerminalOutputEnvelope(
                kind: .chunk,
                retainedBaseSequence: 10,
                sequence: 10,
                currentSequence: 12,
                payload: Data([1])
            )
        }
    }

    @Test
    func decoderRetainsAnIncompleteFrameWithoutEmittingPartialBytes() throws {
        let envelope = try CmxIrohTerminalOutputEnvelope(
            kind: .replay,
            retainedBaseSequence: 0,
            sequence: 0,
            currentSequence: 6,
            payload: Data("output".utf8)
        )
        let encoded = CmxIrohTerminalOutputEnvelopeCodec().encode(envelope)
        var decoder = CmxIrohTerminalOutputEnvelopeDecoder()

        #expect(try decoder.append(encoded.dropLast()).isEmpty)
        #expect(decoder.hasBufferedBytes)
        #expect(try decoder.append(Data(encoded.suffix(1))) == [envelope])
        #expect(!decoder.hasBufferedBytes)
    }
}
