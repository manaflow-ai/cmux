import CmuxTerminalRendererControl
import CmuxTerminalRenderProtocol
import Foundation

struct RendererControlTestFixture {
    let daemonID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let workspaceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let terminalA = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    let terminalB = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    let presentationA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let presentationB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    let rendererEpoch: UInt64 = 7

    func bootstrap() throws -> RendererBootstrap {
        try RendererBootstrap(
            daemonInstanceID: daemonID,
            workspaceID: workspaceID,
            rendererEpoch: rendererEpoch
        )
    }

    func ready() throws -> RendererWorkerReady {
        try RendererWorkerReady(
            processID: 12_345,
            effectiveUserID: 501,
            sceneCapabilities: [.fullScene, .canonicalDelta, .presentationDelta]
        )
    }

    func attachment(
        terminalID: UUID? = nil,
        presentationID: UUID? = nil,
        generation: UInt64 = 1,
        config: Data = Data([0xC0, 0xFF, 0xEE])
    ) throws -> RendererPresentationAttachment {
        try RendererPresentationAttachment(
            terminalID: terminalID ?? terminalA,
            terminalEpoch: 9,
            presentationID: presentationID ?? presentationA,
            presentationGeneration: generation,
            width: 1_280,
            height: 800,
            backingScaleFactor: 2,
            pixelFormat: .bgra8Unorm,
            colorSpace: .displayP3,
            frameEndpoint: TerminalRenderFrameEndpoint(
                serviceName: "dev.cmux.renderer.fixture",
                capability: Data(repeating: 0x5A, count: TerminalRenderFrameProtocol.capabilityLength)
            ),
            resolvedConfigRevision: 11,
            resolvedConfig: config
        )
    }

    func scene(
        terminalID: UUID? = nil,
        presentationID: UUID? = nil,
        generation: UInt64 = 1,
        canonicalSequence: UInt64 = 20,
        presentationSequence: UInt64 = 5,
        bytes: Data = Data([1, 2, 3, 4])
    ) throws -> RendererSemanticScene {
        try RendererSemanticScene(
            terminalID: terminalID ?? terminalA,
            terminalEpoch: 9,
            presentationID: presentationID ?? presentationA,
            presentationGeneration: generation,
            canonicalSequence: canonicalSequence,
            presentationSequence: presentationSequence,
            bytes: bytes
        )
    }

    func release(
        terminalID: UUID? = nil,
        presentationID: UUID? = nil,
        generation: UInt64 = 1
    ) throws -> RendererControlFrameRelease {
        try RendererControlFrameRelease(
            daemonInstanceID: daemonID,
            rendererEpoch: rendererEpoch,
            terminalID: terminalID ?? terminalA,
            terminalEpoch: 9,
            terminalSequence: 20,
            presentationID: presentationID ?? presentationA,
            presentationGeneration: generation,
            frameSequence: 3,
            surfaceID: 42
        )
    }

    func removal(
        terminalID: UUID? = nil,
        presentationID: UUID? = nil,
        generation: UInt64 = 1
    ) throws -> RendererPresentationRemoval {
        try RendererPresentationRemoval(
            terminalID: terminalID ?? terminalA,
            terminalEpoch: 9,
            presentationID: presentationID ?? presentationA,
            presentationGeneration: generation
        )
    }

    func presentationRemoved(
        terminalID: UUID? = nil,
        presentationID: UUID? = nil,
        generation: UInt64 = 1
    ) throws -> RendererPresentationRemoved {
        try RendererPresentationRemoved(
            terminalID: terminalID ?? terminalA,
            terminalEpoch: 9,
            presentationID: presentationID ?? presentationA,
            presentationGeneration: generation
        )
    }

    func needsFullScene(
        terminalID: UUID? = nil,
        presentationID: UUID? = nil,
        generation: UInt64 = 1
    ) throws -> RendererNeedsFullScene {
        try RendererNeedsFullScene(
            terminalID: terminalID ?? terminalA,
            terminalEpoch: 9,
            presentationID: presentationID ?? presentationA,
            presentationGeneration: generation,
            lastCanonicalSequence: 19,
            lastPresentationSequence: 4,
            reason: .sequenceGap
        )
    }

    func presentationReady(
        terminalID: UUID? = nil,
        presentationID: UUID? = nil,
        generation: UInt64 = 1,
        canonicalSequence: UInt64 = 20,
        presentationSequence: UInt64 = 5
    ) throws -> RendererPresentationReady {
        try RendererPresentationReady(
            terminalID: terminalID ?? terminalA,
            terminalEpoch: 9,
            presentationID: presentationID ?? presentationA,
            presentationGeneration: generation,
            canonicalSequence: canonicalSequence,
            presentationSequence: presentationSequence,
            columns: 120,
            rows: 40,
            cellWidth: 9,
            cellHeight: 18,
            paddingTop: 5,
            paddingRight: 6,
            paddingBottom: 7,
            paddingLeft: 8
        )
    }

    func envelope(
        _ message: RendererControlMessage,
        sequence: UInt64
    ) throws -> RendererControlEnvelope {
        try RendererControlEnvelope(
            direction: message.direction,
            sequence: sequence,
            message: message
        )
    }

    func goldenData(named name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "hex",
            subdirectory: "Fixtures"
        ) else {
            throw RendererControlError.invalidPayloadLength
        }
        let value = try String(contentsOf: url, encoding: .utf8)
        let digits = value.filter { !$0.isWhitespace }
        guard digits.count.isMultiple(of: 2) else {
            throw RendererControlError.invalidPayloadLength
        }
        var output = Data()
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else {
                throw RendererControlError.invalidPayloadLength
            }
            output.append(byte)
            index = next
        }
        return output
    }
}
