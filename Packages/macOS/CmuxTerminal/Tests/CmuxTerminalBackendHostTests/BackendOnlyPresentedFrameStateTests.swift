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

    @Test("ten thousand content frames before AX demand schedule zero semantic drains")
    func lateAccessibilityDemandRetainsLatestFrameWithoutFrameCadenceWork() throws {
        let state = BackendOnlyPresentedFrameState()
        var newest = try makeMetadata(terminalSequence: 1, frameSequence: 1)

        for sequence in 1 ... 10_000 {
            newest = try makeMetadata(
                terminalSequence: UInt64(sequence),
                frameSequence: UInt64(sequence)
            )
            #expect(!state.record(newest))
        }
        #expect(state.takeScheduledDrain() == nil)
        #expect(state.latest() == newest)
        #expect(state.demandAccessibility() == newest)

        let afterDemand = try makeMetadata(terminalSequence: 10_001, frameSequence: 10_001)
        #expect(state.record(afterDemand))
        let drain = try #require(state.takeScheduledDrain())
        #expect(drain.metadata == afterDemand)
        #expect(drain.accessibilityDemanded)
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
