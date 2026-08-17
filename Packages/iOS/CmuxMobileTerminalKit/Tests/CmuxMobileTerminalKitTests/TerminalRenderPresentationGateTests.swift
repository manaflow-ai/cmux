import Testing
@testable import CmuxMobileTerminalKit

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

        _ = gate.setSuppressed(true)
        #expect(gate.enqueue(ordinary) == .queued(ordinary))
        #expect(gate.inFlight == nil)
        #expect(gate.pending == ordinary)
        #expect(gate.enqueue(replay) == .started(replay))
        #expect(gate.complete(token: 20, generation: 4) == .idle)
        #expect(gate.pending == ordinary)
        #expect(gate.setSuppressed(false) == .started(ordinary))
        #expect(gate.inFlight == ordinary)
    }

    @Test("suppression holds and resumes an exact local scroll frame")
    func suppressionResumesLocalScrollFrame() {
        var gate = TerminalRenderPresentationGate()
        let localScroll = TerminalRenderSubmission(
            token: 22,
            generation: 4,
            kind: .localScroll
        )

        _ = gate.setSuppressed(true)
        #expect(gate.enqueue(localScroll) == .queued(localScroll))
        #expect(gate.inFlight == nil)
        #expect(gate.pending == localScroll)
        #expect(gate.setSuppressed(false) == .started(localScroll))
        #expect(gate.inFlight == localScroll)
        #expect(gate.pending == nil)
    }

    @Test("a replay cannot be displaced by a newer ordinary frame")
    func replayPendingFrameWinsOverLaterOrdinaryFrame() {
        var gate = TerminalRenderPresentationGate()
        let first = TerminalRenderSubmission(
            token: 23,
            generation: 4,
            kind: .ordinary
        )
        let replay = TerminalRenderSubmission(
            token: 24,
            generation: 4,
            kind: .verifiedReplay
        )
        let newerOrdinary = TerminalRenderSubmission(
            token: 25,
            generation: 4,
            kind: .ordinary
        )

        #expect(gate.enqueue(first) == .started(first))
        #expect(gate.enqueue(replay) == .queued(replay))
        #expect(gate.enqueue(newerOrdinary) == .queued(newerOrdinary))
        #expect(gate.pending == replay)
        #expect(gate.complete(token: first.token, generation: first.generation) == .started(replay))
        #expect(gate.inFlight == replay)
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

    @Test("a pre-output frame cannot reveal the fallback for newer output")
    func preOutputFrameCannotRevealNewerOutput() {
        let preOutput = TerminalRenderSubmission(
            token: 40,
            generation: 6,
            kind: .ordinary,
            outputRevision: 0
        )
        let output = TerminalRenderSubmission(
            token: 41,
            generation: 6,
            kind: .ordinary,
            outputRevision: 1
        )

        #expect(!preOutput.carriesOutputRevision(1))
        #expect(output.carriesOutputRevision(1))
    }
}
