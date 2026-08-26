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

        #expect(gate.setSuppressed(true) == .idle)
        #expect(gate.enqueue(ordinary) == .queued(ordinary))
        #expect(gate.inFlight == nil)
        #expect(gate.pending == ordinary)
        #expect(gate.enqueue(replay) == .started(replay))
        #expect(gate.complete(token: 20, generation: 4) == .idle)
        #expect(gate.pending == ordinary)
        #expect(gate.setSuppressed(false) == .started(ordinary))
        #expect(gate.inFlight == ordinary)
    }

    @Test("cancelling a failed frame releases the newest pending frame")
    func failedFrameDoesNotStarveOutput() {
        var gate = TerminalRenderPresentationGate()
        let failed = TerminalRenderSubmission(
            token: 30,
            generation: 5,
            kind: .verifiedReplay
        )
        let ordinary = TerminalRenderSubmission(
            token: 31,
            generation: 5,
            kind: .ordinary
        )

        #expect(gate.enqueue(failed) == .started(failed))
        #expect(gate.enqueue(ordinary) == .queued(ordinary))
        #expect(gate.cancel(token: 99, generation: 5) == .ignored)
        #expect(gate.cancel(token: 30, generation: 5) == .started(ordinary))
        #expect(gate.inFlight == ordinary)
        #expect(gate.pending == nil)
    }

    @Test("geometry replacement invalidates the old token")
    func geometryReplacementStartsImmediately() {
        var gate = TerminalRenderPresentationGate()
        let old = TerminalRenderSubmission(
            token: 40,
            generation: 6,
            kind: .localScroll
        )
        let replacement = TerminalRenderSubmission(
            token: 41,
            generation: 6,
            kind: .localScroll
        )

        #expect(gate.enqueue(old) == .started(old))
        #expect(gate.replaceInFlight(with: replacement) == .started(replacement))
        #expect(gate.complete(token: old.token, generation: old.generation) == .ignored)
        #expect(gate.inFlight == replacement)
        #expect(gate.complete(token: replacement.token, generation: replacement.generation) == .idle)
    }

    @Test("a pending verified replay is not superseded by ordinary frames")
    func pendingReplaySurvivesOrdinaryFrames() {
        var gate = TerminalRenderPresentationGate()
        let inFlight = TerminalRenderSubmission(
            token: 50,
            generation: 7,
            kind: .ordinary
        )
        let replay = TerminalRenderSubmission(
            token: 51,
            generation: 7,
            kind: .verifiedReplay
        )
        let newerOrdinary = TerminalRenderSubmission(
            token: 52,
            generation: 7,
            kind: .ordinary
        )

        #expect(gate.enqueue(inFlight) == .started(inFlight))
        #expect(gate.enqueue(replay) == .queued(replay))
        #expect(gate.enqueue(newerOrdinary) == .queued(newerOrdinary))
        #expect(gate.pending == replay)
        #expect(gate.complete(token: inFlight.token, generation: inFlight.generation) == .started(replay))
    }
}
#endif
