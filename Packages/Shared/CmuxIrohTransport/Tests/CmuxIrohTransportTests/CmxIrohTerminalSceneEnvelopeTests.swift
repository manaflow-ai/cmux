import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohTerminalSceneEnvelopeTests {
    private let terminalID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let presentationID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    @Test
    func configurationAndEverySceneKindRoundTripWithoutConsumingTheNextEnvelope() throws {
        let codec = CmxIrohTerminalSceneEnvelopeCodec()
        let configuration = try CmxIrohTerminalSceneConfiguration(
            terminalID: terminalID,
            terminalEpoch: 9,
            presentationID: presentationID,
            presentationGeneration: 7,
            rendererConfigRevision: 4,
            width: 2_358,
            height: 1_290,
            contentScale: 3,
            rendererConfig: Data("font-family = JetBrains Mono\n".utf8)
        )
        let envelopes: [CmxIrohTerminalSceneEnvelope] = [
            .configuration(configuration),
            .scene(try scene(kind: .full, contentSequence: 21, presentationSequence: 1)),
            .scene(try scene(kind: .delta, contentSequence: 22, presentationSequence: 2)),
            .scene(try scene(kind: .unchanged, contentSequence: 22, presentationSequence: 3)),
        ]
        let encoded = envelopes.map(codec.encode)
        let joined = encoded.reduce(into: Data(), +=)

        var offset = 0
        for (expected, frame) in zip(envelopes, encoded) {
            let decoded = try codec.decodePrefix(joined.dropFirst(offset))
            #expect(decoded.envelope == expected)
            #expect(decoded.consumedByteCount == frame.count)
            offset += decoded.consumedByteCount
        }
        #expect(offset == joined.count)
    }

    @Test
    func incrementalDecoderHandlesEveryNetworkSplitAndRejectsTruncationAtFinish() throws {
        let codec = CmxIrohTerminalSceneEnvelopeCodec()
        let envelopes: [CmxIrohTerminalSceneEnvelope] = [
            .configuration(try configuration()),
            .scene(try scene(kind: .full, contentSequence: 21, presentationSequence: 1)),
            .scene(try scene(kind: .delta, contentSequence: 22, presentationSequence: 2)),
        ]
        let bytes = envelopes.map(codec.encode).reduce(into: Data(), +=)

        for split in 0 ... bytes.count {
            var decoder = CmxIrohTerminalSceneEnvelopeDecoder()
            let first = try decoder.append(bytes.prefix(split))
            let second = try decoder.append(bytes.dropFirst(split))
            try decoder.finish()
            #expect(first + second == envelopes)
        }

        var truncated = CmxIrohTerminalSceneEnvelopeDecoder()
        _ = try truncated.append(bytes.dropLast())
        #expect(throws: CmxIrohTerminalSceneEnvelopeCodec.DecodeError.incompleteFrame) {
            try truncated.finish()
        }
    }

    @Test
    func declaredOversizeSceneIsRejectedAfterOnlyTheFixedHeader() throws {
        var header = Data("CMXSCN01".utf8)
        header.append(contentsOf: [1, 2, 0, 0])
        append(UInt32(CmxIrohTerminalSceneFrame.maximumPayloadByteCount + 1), to: &header)
        var decoder = CmxIrohTerminalSceneEnvelopeDecoder()

        #expect(
            throws: CmxIrohTerminalSceneEnvelopeCodec.DecodeError.payloadTooLarge(
                actual: CmxIrohTerminalSceneFrame.maximumPayloadByteCount + 1,
                maximum: CmxIrohTerminalSceneFrame.maximumPayloadByteCount
            )
        ) {
            try decoder.append(header)
        }
    }

    @Test
    func streamValidatorRequiresConfigurationThenFullAndContiguousPresentationSequence() throws {
        var validator = CmxIrohTerminalSceneStreamValidator(
            presentationID: presentationID,
            presentationGeneration: 7
        )

        #expect(throws: CmxIrohTerminalSceneStreamValidator.ValidationError.missingConfiguration) {
            try validator.accept(
                .scene(try scene(kind: .full, contentSequence: 21, presentationSequence: 1))
            )
        }

        try validator.accept(.configuration(try configuration()))
        #expect(throws: CmxIrohTerminalSceneStreamValidator.ValidationError.missingFullScene) {
            try validator.accept(
                .scene(try scene(kind: .delta, contentSequence: 21, presentationSequence: 1))
            )
        }

        try validator.accept(
            .scene(try scene(kind: .full, contentSequence: 21, presentationSequence: 1))
        )
        try validator.accept(
            .scene(try scene(kind: .unchanged, contentSequence: 21, presentationSequence: 2))
        )
        try validator.accept(
            .scene(try scene(kind: .delta, contentSequence: 24, presentationSequence: 3))
        )

        #expect(
            throws: CmxIrohTerminalSceneStreamValidator.ValidationError
                .presentationSequenceGap(expected: 4, actual: 5)
        ) {
            try validator.accept(
                .scene(try scene(kind: .delta, contentSequence: 25, presentationSequence: 5))
            )
        }
    }

    @Test
    func streamValidatorRejectsCrossTerminalAndCrossPresentationFrames() throws {
        var validator = CmxIrohTerminalSceneStreamValidator(
            presentationID: presentationID,
            presentationGeneration: 7
        )
        try validator.accept(.configuration(try configuration()))

        let otherTerminal = try CmxIrohTerminalSceneFrame(
            terminalID: UUID(uuidString: "ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            terminalEpoch: 9,
            contentSequence: 21,
            presentationID: presentationID,
            presentationGeneration: 7,
            presentationSequence: 1,
            kind: .full,
            payload: Data([1])
        )
        #expect(throws: CmxIrohTerminalSceneStreamValidator.ValidationError.identityMismatch) {
            try validator.accept(.scene(otherTerminal))
        }

        let otherPresentation = try CmxIrohTerminalSceneFrame(
            terminalID: terminalID,
            terminalEpoch: 9,
            contentSequence: 21,
            presentationID: UUID(uuidString: "99999999-2222-3333-4444-555555555555")!,
            presentationGeneration: 7,
            presentationSequence: 1,
            kind: .full,
            payload: Data([1])
        )
        #expect(throws: CmxIrohTerminalSceneStreamValidator.ValidationError.identityMismatch) {
            try validator.accept(.scene(otherPresentation))
        }
    }

    private func configuration() throws -> CmxIrohTerminalSceneConfiguration {
        try CmxIrohTerminalSceneConfiguration(
            terminalID: terminalID,
            terminalEpoch: 9,
            presentationID: presentationID,
            presentationGeneration: 7,
            rendererConfigRevision: 4,
            width: 2_358,
            height: 1_290,
            contentScale: 3,
            rendererConfig: Data("font-family = JetBrains Mono\n".utf8)
        )
    }

    private func scene(
        kind: CmxIrohTerminalSceneFrame.Kind,
        contentSequence: UInt64,
        presentationSequence: UInt64
    ) throws -> CmxIrohTerminalSceneFrame {
        try CmxIrohTerminalSceneFrame(
            terminalID: terminalID,
            terminalEpoch: 9,
            contentSequence: contentSequence,
            presentationID: presentationID,
            presentationGeneration: 7,
            presentationSequence: presentationSequence,
            kind: kind,
            payload: Data([0xca, 0xfe, UInt8(truncatingIfNeeded: presentationSequence)])
        )
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}
