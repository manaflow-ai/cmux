import Foundation
import Testing
@testable import CmuxTerminalRenderCompositor
@testable import CmuxTerminalRenderProtocol

struct TerminalRenderCompositorAdmissionTests {
    @Test
    func acceptsOnlyExactMonotonicPresentationFrames() throws {
        let fence = try makeFence()
        var admission = TerminalRenderCompositorAdmission(fence: fence)

        #expect(admission.accept(try makeMetadata(fence: fence, frameSequence: 1)) == nil)
        #expect(
            admission.accept(try makeMetadata(fence: fence, frameSequence: 1))
                == .staleFrameSequence
        )
        #expect(admission.accept(try makeMetadata(fence: fence, frameSequence: 2)) == nil)
    }

    @Test
    func resetRejectsDetachedGenerationAndAcceptsNewGeneration() throws {
        let oldFence = try makeFence(generation: 7)
        let newFence = try makeFence(generation: 8)
        var admission = TerminalRenderCompositorAdmission(fence: oldFence)
        #expect(admission.accept(try makeMetadata(fence: oldFence, frameSequence: 1)) == nil)

        admission.reset(fence: newFence)
        #expect(
            admission.accept(try makeMetadata(fence: oldFence, frameSequence: 2))
                == .presentationGenerationMismatch
        )
        #expect(admission.accept(try makeMetadata(fence: newFence, frameSequence: 1)) == nil)
    }

    private func makeFence(
        generation: UInt64 = 7
    ) throws -> TerminalRenderPresentationFence {
        try TerminalRenderPresentationFence(
            daemonInstanceID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            rendererEpoch: 3,
            terminalID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            terminalEpoch: 5,
            minimumTerminalSequence: 11,
            presentationID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            presentationGeneration: generation,
            width: 800,
            height: 600,
            pixelFormat: .bgra8Unorm,
            colorSpace: .sRGB,
            completionRequirement: .producerCompleted
        )
    }

    private func makeMetadata(
        fence: TerminalRenderPresentationFence,
        frameSequence: UInt64
    ) throws -> TerminalRenderFrameMetadata {
        try TerminalRenderFrameMetadata(
            daemonInstanceID: fence.daemonInstanceID,
            rendererEpoch: fence.rendererEpoch,
            terminalID: fence.terminalID,
            terminalEpoch: fence.terminalEpoch,
            terminalSequence: fence.minimumTerminalSequence,
            presentationID: fence.presentationID,
            presentationGeneration: fence.presentationGeneration,
            frameSequence: frameSequence,
            width: fence.width,
            height: fence.height,
            pixelFormat: fence.pixelFormat,
            colorSpace: fence.colorSpace,
            completionFence: .producerCompleted,
            damageBounds: nil
        )
    }
}
