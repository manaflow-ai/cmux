import CmuxTerminalRenderProtocol
import Foundation
import Testing
@testable import CmuxTerminalBackendHost

@Suite("Backend-only presented frame scheduling")
struct BackendOnlyPresentedFrameStateTests {
    @Test("animation and content bursts schedule one newest-frame drain")
    func frameBurstsCoalesceToNewestSemanticFrame() throws {
        let state = BackendOnlyPresentedFrameState()
        state.demandAccessibility()
        let first = try makeMetadata(terminalSequence: 10, frameSequence: 1)
        let animation = try makeMetadata(terminalSequence: 10, frameSequence: 2)
        let newest = try makeMetadata(terminalSequence: 11, frameSequence: 3)

        #expect(state.record(first))
        #expect(!state.record(animation))
        #expect(!state.record(newest))
        #expect(state.latest() == newest)
        let drain = try #require(state.takeScheduledDrain())
        #expect(drain.metadata == newest)
        #expect(drain.accessibilityDemanded)
        #expect(state.record(try makeMetadata(terminalSequence: 12, frameSequence: 4)))
    }

    @Test("UX schedules before AX demand and late AX demand retains the latest frame")
    func lateAccessibilityDemandRetainsLatestFrame() throws {
        let state = BackendOnlyPresentedFrameState()
        let frame = try makeMetadata(terminalSequence: 20, frameSequence: 1)

        #expect(state.record(frame))
        let drain = try #require(state.takeScheduledDrain())
        #expect(drain.metadata == frame)
        #expect(!drain.accessibilityDemanded)
        #expect(state.demandAccessibility() == frame)
        #expect(state.latest() == frame)
    }

    @Test("presentation reset admits the first frame of the replacement")
    func resetAdmitsReplacementFrame() throws {
        let state = BackendOnlyPresentedFrameState()
        state.demandAccessibility()
        let frame = try makeMetadata(terminalSequence: 30, frameSequence: 1)

        #expect(state.record(frame))
        state.reset()
        #expect(state.record(frame))
    }

    private func makeMetadata(
        terminalSequence: UInt64,
        frameSequence: UInt64
    ) throws -> TerminalRenderFrameMetadata {
        try TerminalRenderFrameMetadata(
            daemonInstanceID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            rendererEpoch: 1,
            terminalID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            terminalEpoch: 1,
            terminalSequence: terminalSequence,
            presentationID: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            presentationGeneration: 1,
            frameSequence: frameSequence,
            width: 800,
            height: 600,
            pixelFormat: .bgra8Unorm,
            colorSpace: .sRGB,
            completionFence: .producerCompleted,
            damageBounds: nil
        )
    }
}
