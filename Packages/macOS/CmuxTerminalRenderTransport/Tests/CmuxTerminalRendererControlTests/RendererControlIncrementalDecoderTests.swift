import CmuxTerminalRendererControl
import Foundation
import Testing

@Suite
struct RendererControlIncrementalDecoderTests {
    private let fixture = RendererControlTestFixture()

    @Test
    func byteAtATimeFragmentationProducesOneFrame() throws {
        var encoder = RendererControlEncoder(direction: .daemonToWorker)
        let frame = try encoder.encode(.bootstrap(fixture.bootstrap()))
        var decoder = RendererControlIncrementalDecoder(expectedDirection: .daemonToWorker)
        var decoded: [RendererControlEnvelope] = []
        for byte in frame {
            decoded.append(contentsOf: try decoder.feed(Data([byte])))
        }
        try decoder.finish()
        #expect(decoded.count == 1)
        #expect(decoded.first?.message == .bootstrap(try fixture.bootstrap()))
        #expect(decoder.bufferedByteCount == 0)
        #expect(decoder.maximumObservedBufferedByteCount == frame.count)
    }

    @Test
    func coalescedFramesAreDrainedWithoutRetainingTheSecondFrame() throws {
        var encoder = RendererControlEncoder(direction: .daemonToWorker)
        var bytes = try encoder.encode(.bootstrap(fixture.bootstrap()))
        bytes.append(try encoder.encode(.shutdown))
        var decoder = RendererControlIncrementalDecoder(expectedDirection: .daemonToWorker)
        let decoded = try decoder.feed(bytes)
        try decoder.finish()
        #expect(decoded.map(\.sequence) == [1, 2])
        #expect(decoded.last?.message == .shutdown)
        #expect(decoder.bufferedByteCount == 0)
        #expect(decoder.maximumObservedBufferedByteCount < bytes.count)
        #expect(decoder.maximumObservedBufferedByteCount <= RendererControlProtocol.maximumFrameLength)
    }

    @Test
    func replayAndGapPoisonTheirDecoder() throws {
        let frameOne = try RendererControlWire().encode(fixture.envelope(
            .bootstrap(fixture.bootstrap()),
            sequence: 1
        ))
        var replayDecoder = RendererControlIncrementalDecoder(expectedDirection: .daemonToWorker)
        #expect(try replayDecoder.feed(frameOne).count == 1)
        #expect(throws: RendererControlError.invalidSequence(expected: 2, actual: 1)) {
            try replayDecoder.feed(frameOne)
        }
        #expect(throws: RendererControlError.decoderFailed) {
            try replayDecoder.feed(Data())
        }

        let frameTwo = try RendererControlWire().encode(fixture.envelope(
            .bootstrap(fixture.bootstrap()),
            sequence: 2
        ))
        var gapDecoder = RendererControlIncrementalDecoder(expectedDirection: .daemonToWorker)
        #expect(throws: RendererControlError.invalidSequence(expected: 1, actual: 2)) {
            try gapDecoder.feed(frameTwo)
        }
    }

    @Test
    func truncationIsRejectedOnlyWhenTheStreamFinishes() throws {
        var encoder = RendererControlEncoder(direction: .daemonToWorker)
        let frame = try encoder.encode(.bootstrap(fixture.bootstrap()))
        var decoder = RendererControlIncrementalDecoder(expectedDirection: .daemonToWorker)
        #expect(try decoder.feed(frame.dropLastData()).isEmpty)
        #expect(throws: RendererControlError.truncatedFrame) {
            try decoder.finish()
        }
    }

    @Test
    func oversizedSceneHeaderFailsBeforeAllocatingItsDeclaredBody() throws {
        var frame = try RendererControlWire().encode(fixture.envelope(
            .semanticScene(try fixture.scene()),
            sequence: 1
        ))
        let oneOver = UInt64(80 + RendererControlProtocol.maximumSemanticSceneLength + 1).bigEndianBytes
        frame.replaceSubrange(24..<32, with: oneOver)
        var decoder = RendererControlIncrementalDecoder(expectedDirection: .daemonToWorker)
        #expect(throws: RendererControlError.invalidPayloadLength) {
            try decoder.feed(frame.prefixData(RendererControlProtocol.headerLength))
        }
        #expect(decoder.bufferedByteCount == 0)
        #expect(decoder.maximumObservedBufferedByteCount == RendererControlProtocol.headerLength)
    }
}

private extension Data {
    func dropLastData() -> Data {
        Data(dropLast())
    }

    func prefixData(_ count: Int) -> Data {
        Data(prefix(count))
    }
}

private extension UInt64 {
    var bigEndianBytes: [UInt8] {
        var value = bigEndian
        return withUnsafeBytes(of: &value) { Array($0) }
    }
}
