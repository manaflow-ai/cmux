import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A chat pane nobody can see gets its frames at most every ``AgentPaneFramePacer/hiddenInterval``.
/// With twenty mostly hidden chats streaming, each took a main-thread `evaluateJavaScript` per
/// frame interval, and the app beachballed until it was force-quit (2026-10-20, 22:14-22:27:
/// deliveries went from about 300 to 2,100 a minute). A visible pane keeps display-frame pacing.
@MainActor
struct AgentPaneHiddenPacingTests {
    final class Ticks: AgentPaneFrameTicks {
        var onTick: (@MainActor () -> Void)?
        func activate() {}
        func deactivate() {}
    }

    final class Deadline: AgentPaneFallbackDeadline {
        var delay: Duration?
        var action: (@MainActor @Sendable () -> Void)?
        func schedule(after delay: Duration, _ action: @escaping @MainActor @Sendable () -> Void) {
            self.delay = delay
            self.action = action
        }
        func cancel() {
            delay = nil
            action = nil
        }
        func fire() {
            let action = action
            cancel()
            action?()
        }
    }

    final class Rig {
        var clock: TimeInterval = 100
        var hidden: Bool
        var turns: [@MainActor @Sendable () -> Void] = []
        var calls = 0
        let deadline = Deadline()
        lazy var pacer = AgentPaneFramePacer(
            frames: Ticks(), fallback: deadline, now: { [unowned self] in self.clock },
            nextTurn: { [unowned self] work in self.turns.append(work) },
            isHidden: { [unowned self] in self.hidden })

        init(hidden: Bool) { self.hidden = hidden }

        /// Frames arrive; the flush delivers them in one call.
        func arrive() {
            pacer.schedule { [unowned self] in
                self.calls += 1
                return AgentPaneFlush(delivered: true, more: false)
            }
        }
    }

    @Test func aHiddenPaneGetsAStreamAtMostEveryQuarterSecond() {
        let rig = Rig(hidden: true)
        // Idle: the first frames go at once.
        rig.arrive()
        #expect(rig.calls == 1)
        // The page ran it; more frames come 50 ms later and wait out the interval.
        rig.clock += 0.05
        rig.pacer.delivered()
        rig.arrive()
        #expect(rig.calls == 1, "a hidden pane got a second call within its interval")
        #expect(rig.deadline.delay.map { $0 > .milliseconds(199) && $0 <= .milliseconds(201) } == true)
        rig.clock += 0.2
        rig.deadline.fire()
        #expect(rig.calls == 2)
    }

    @Test func aVisiblePaneStillGetsFramesAtOnce() {
        let rig = Rig(hidden: false)
        rig.arrive()
        rig.clock += 0.05
        rig.pacer.delivered()
        rig.arrive()
        #expect(rig.calls == 2)
        #expect(rig.deadline.delay == nil)
    }

    @Test func aPaneThatShowsAgainGetsItsWaitingFramesAtTheDeadline() {
        let rig = Rig(hidden: true)
        rig.arrive()
        rig.pacer.delivered()
        rig.arrive()
        #expect(rig.calls == 1)
        rig.hidden = false
        rig.clock += 0.25
        rig.deadline.fire()
        #expect(rig.calls == 2)
        // Shown now: the next frames go at once.
        rig.pacer.delivered()
        rig.arrive()
        #expect(rig.calls == 3)
    }
}
