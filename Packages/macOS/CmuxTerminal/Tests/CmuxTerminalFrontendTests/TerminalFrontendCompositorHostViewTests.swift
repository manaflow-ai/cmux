import AppKit
import CmuxTerminalFrontend
import CmuxTerminalRenderProtocol
import Foundation
import Testing

@MainActor
@Suite struct TerminalFrontendCompositorHostViewTests {
    @Test func injectedCompositorFillsHostAndRetires() throws {
        let initialFence = try makeFence(generation: 1)
        let fake = FakeTerminalFrontendCompositor(
            frameIngress: FakeTerminalFrontendFrameIngress(),
            fence: initialFence
        )
        let host = TerminalFrontendCompositorHostView(compositor: fake)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        host.layout()
        let replacementFence = try makeFence(generation: 2)
        host.updateFence(replacementFence)
        host.retire()

        #expect(fake.frame == host.bounds)
        #expect(fake.installedFence == replacementFence)
        #expect(fake.retired)
    }

    private func makeFence(generation: UInt64) throws -> TerminalRenderPresentationFence {
        try TerminalRenderPresentationFence(
            daemonInstanceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            rendererEpoch: 1,
            terminalID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            terminalEpoch: 1,
            minimumTerminalSequence: 1,
            presentationID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            presentationGeneration: generation,
            width: 800,
            height: 600,
            pixelFormat: .bgra8Unorm,
            colorSpace: .sRGB,
            completionRequirement: .producerCompleted
        )
    }
}
