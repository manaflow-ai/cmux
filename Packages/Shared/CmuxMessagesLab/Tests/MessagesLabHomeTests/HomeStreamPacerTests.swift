import Testing
@testable import MessagesLabHome

/// One streamed-text commit per display frame, never ahead of a keystroke, and
/// never starved by typing in every frame (HomeStreamPacer).
@MainActor struct HomeStreamPacerTests {
    /// A display clock the test advances: `nextFrame` work runs at `tick()`.
    final class Frames {
        var pending: [() -> Void] = []
        lazy var nextFrame: (@escaping () -> Void) -> Void = { [unowned self] in self.pending.append($0) }
        func tick() { let w = pending; pending.removeAll(); for f in w { f() } }
    }

    @Test func theFirstTokenOfAFrameCommitsTheRestWaitForTheNextFrame() {
        let pacer = HomeStreamPacer(), frames = Frames()
        var refreshes = 0
        func token() -> Bool {
            pacer.admit(inputFrame: false, nextFrame: frames.nextFrame) { refreshes += 1; _ = token() }
        }
        #expect(token())
        // Four more tokens in the same frame: none commits now, one refresh is due.
        for _ in 0..<4 { #expect(!token()) }
        #expect(pacer.commits == 1 && pacer.held == 1 && pacer.merged == 3)
        #expect(refreshes == 0)
        frames.tick()
        // The frame's start reads the newest text once, and it commits.
        #expect(refreshes == 1 && pacer.commits == 2)
        // The next frame: its first token commits at once again (the flag cleared at its start).
        frames.tick()
        #expect(token())
    }

    @Test func aSendFlushesTheHeldUpdateNow() {
        let pacer = HomeStreamPacer(), frames = Frames()
        var refreshes = 0
        func token() -> Bool { pacer.admit(inputFrame: false, nextFrame: frames.nextFrame) { refreshes += 1; _ = token() } }
        #expect(token())
        #expect(!token())
        var admitted = false
        pacer.flush { admitted = token() }
        #expect(admitted, "the flushed refresh commits in the same frame")
        // Nothing is held now: the next frame's start runs no refresh.
        frames.tick()
        #expect(refreshes == 0)
        pacer.flush { Issue.record("no update was held") }
    }

    @Test func aKeystrokeFrameHoldsTheStreamButTypingEveryFrameNeverStarvesIt() {
        let pacer = HomeStreamPacer(), frames = Frames()
        var shown = 0
        func token() -> Bool {
            let now = pacer.admit(inputFrame: true, nextFrame: frames.nextFrame) { _ = token() }
            if now { shown += 1 }
            return now
        }
        // Every frame has a keystroke before its tokens.
        for _ in 0..<10 {
            #expect(!token(), "a token waits behind the frame's keystroke")
            frames.tick()
        }
        // Each frame's start showed the stream: one commit per frame, none lost.
        #expect(shown == 10)
    }
}
