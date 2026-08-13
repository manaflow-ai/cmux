#if canImport(UIKit)
import Testing
@testable import CmuxMobileTerminal

@Suite("Terminal render presentation gate")
struct TerminalRenderPresentationGateTests {
    @Test("only the exact presented token releases the current frame")
    func stalePresentationCannotReleaseCurrentFrame() {
        var gate = TerminalRenderPresentationGate()
        let first = TerminalRenderSubmission(
            token: 11,
            generation: 3,
            kind: .ordinary
        )
        let newest = TerminalRenderSubmission(
            token: 12,
            generation: 3,
            kind: .localScroll
        )

        #expect(gate.enqueue(first) == .started(first))
        #expect(gate.enqueue(newest) == .queued(newest))
        #expect(gate.complete(token: 99, generation: 3) == .ignored)
        #expect(gate.inFlight == first)
        #expect(gate.pending == newest)
        #expect(gate.complete(token: 11, generation: 3) == .started(newest))
        #expect(gate.inFlight == newest)
        #expect(gate.pending == nil)
    }

    @Test("suppression holds ordinary frames and resumes the newest one")
    func suppressionResumesNewestPendingFrame() {
        var gate = TerminalRenderPresentationGate()
        let replay = TerminalRenderSubmission(
            token: 20,
            generation: 4,
            kind: .verifiedReplay
        )
        let ordinary = TerminalRenderSubmission(
            token: 21,
            generation: 4,
            kind: .ordinary
        )

        gate.setSuppressed(true)
        #expect(gate.enqueue(ordinary) == .queued(ordinary))
        #expect(gate.inFlight == nil)
        #expect(gate.pending == ordinary)
        #expect(gate.enqueue(replay) == .started(replay))
        #expect(gate.complete(token: 20, generation: 4) == .idle)
        #expect(gate.pending == ordinary)
        #expect(gate.setSuppressed(false) == .started(ordinary))
        #expect(gate.inFlight == ordinary)
    }
}
#endif
