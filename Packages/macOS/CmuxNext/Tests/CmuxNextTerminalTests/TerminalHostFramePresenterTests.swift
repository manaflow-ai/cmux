@testable import CmuxNextTerminal
import QuartzCore
import Testing

/// The pre-commit present of resized terminals: one pass per main run-loop turn with a
/// resized terminal, ahead of its commit, that asks each resized terminal once; nothing is scheduled at
/// rest; a released terminal is not asked; and a pass never waits.
@MainActor
@Suite struct TerminalHostFramePresenterTests {
    /// The run loop's before-commit stage, run by the test.
    @MainActor final class Turns {
        var due: [@MainActor () -> Void] = []

        func schedule(_ body: @escaping @MainActor () -> Void) { due.append(body) }

        /// This turn's commit: runs what was scheduled ahead of it.
        func commit() {
            let now = due
            due.removeAll()
            for body in now { body() }
        }
    }

    @MainActor final class Terminal {
        var presents = 0
    }

    @Test func oneScheduledPassPerTurnAsksEachResizedTerminalOnce() {
        let turns = Turns(), host = CALayer()
        let presenter = TerminalHostFramePresenter(schedule: { _, body in turns.schedule(body) })
        let a = Terminal(), b = Terminal()
        // A divider drag step resizes both terminals, one of them twice (layout, then a fitted size).
        presenter.sizeChanged(of: a, in: host) { a.presents += 1 }
        presenter.sizeChanged(of: b, in: host) { b.presents += 1 }
        presenter.sizeChanged(of: a, in: host) { a.presents += 1 }
        #expect(turns.due.count == 1, "one observer for the turn, however many resizes")
        turns.commit()
        #expect(a.presents == 1 && b.presents == 1)
        #expect(presenter.passes == 1 && presenter.presents == 2)

        // A turn with no resize schedules nothing.
        turns.commit()
        #expect(turns.due.isEmpty && presenter.passes == 1)

        // The next resize schedules the next turn's pass.
        presenter.sizeChanged(of: b, in: host) { b.presents += 1 }
        #expect(turns.due.count == 1)
        turns.commit()
        #expect(a.presents == 1 && b.presents == 2)
    }

    @Test func aTerminalReleasedBeforeTheCommitIsNotAsked() {
        let turns = Turns(), host = CALayer()
        let presenter = TerminalHostFramePresenter(schedule: { _, body in turns.schedule(body) })
        let asked = Terminal()
        var terminal: Terminal? = Terminal()
        weak let released = terminal
        if let terminal { presenter.sizeChanged(of: terminal, in: host) { [weak terminal] in if terminal != nil { asked.presents += 1 } } }
        terminal = nil
        #expect(released == nil, "the pending present keeps its terminal alive")
        turns.commit()
        #expect(asked.presents == 0)
        #expect(presenter.passes == 1)
    }

    /// The present itself never waits for a frame (Ghostty's never-waiting present); the pass adds only
    /// its own bookkeeping: 64 terminals in one pass stay far under a frame's main-thread budget.
    @Test func aPassOfManyTerminalsStaysUnderAMillisecond() {
        let turns = Turns(), host = CALayer()
        let presenter = TerminalHostFramePresenter(schedule: { _, body in turns.schedule(body) })
        let terminals = (0..<64).map { _ in Terminal() }
        for terminal in terminals { presenter.sizeChanged(of: terminal, in: host) { terminal.presents += 1 } }
        turns.commit()
        #expect(terminals.allSatisfy { $0.presents == 1 })
        #expect(presenter.longestPass < .milliseconds(1), "a pass took \(presenter.longestPass)")
    }
}
