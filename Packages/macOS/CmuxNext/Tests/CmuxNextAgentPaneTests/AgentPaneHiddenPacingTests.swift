import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A chat pane nobody can see gets the frames its page waits on at most every
/// ``AgentPaneFramePacer/hiddenInterval``, and the rest when it shows (``AgentPaneHiddenHoldTests``).
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

        /// Flushes still to report `more` (a backlog).
        var capped = 0

        /// Frames arrive (`urgent`: the page waits on them); the flush delivers them in one call,
        /// and says `more` the next `capped` times.
        func arrive(urgent: Bool = false, answers: Bool = false, capped: Int = 0) {
            self.capped = capped
            pacer.schedule(urgent: urgent || answers, answers: answers) { [unowned self] in
                self.calls += 1
                self.capped -= 1
                return AgentPaneFlush(delivered: true, more: self.capped >= 0)
            }
        }
    }

    @Test func aHiddenPaneGetsFramesItsPageWaitsOnAtMostEveryQuarterSecond() {
        let rig = Rig(hidden: true)
        // Idle: the first frames go at once.
        rig.arrive(urgent: true)
        #expect(rig.calls == 1)
        // The page ran it; more frames come 62.5 ms later and wait out the interval. 1/16 s and the
        // 0.25 s interval are exact in binary, so the wait is exactly 187.5 ms on the fake clock.
        rig.clock += 0.0625
        rig.pacer.delivered()
        rig.arrive(urgent: true)
        #expect(rig.calls == 1, "a hidden pane got a second call within its interval")
        #expect(rig.deadline.delay == .nanoseconds(187_500_000))
        rig.clock += 0.2
        rig.deadline.fire()
        #expect(rig.calls == 2)
    }

    /// A chat opening while nobody saw it (behind its cover, in a covered window) read its attach,
    /// permission groups and handoff about 280 ms late, and each later page of history 250 ms late
    /// (chat-open bench, 2026-10-31): replies to the page's own requests skip the hidden interval.
    @Test func aHiddenPaneGetsRepliesToItsOwnRequestsAtOnce() {
        let rig = Rig(hidden: true)
        rig.arrive(answers: true)
        #expect(rig.calls == 1)
        rig.clock += 0.0625
        rig.pacer.delivered()
        rig.arrive(answers: true)
        #expect(rig.calls == 2, "a hidden pane's reply waited out the hidden interval")
        #expect(rig.deadline.delay == nil)
    }

    @Test func aReplyCutsARunningHiddenWaitShort() {
        let rig = Rig(hidden: true)
        rig.arrive(urgent: true)
        rig.clock += 0.0625
        rig.pacer.delivered()
        // A turn's end waits out the interval...
        rig.arrive(urgent: true)
        #expect(rig.calls == 1)
        #expect(rig.deadline.delay != nil)
        // ...until a reply arrives: both go now.
        rig.arrive(answers: true)
        #expect(rig.calls == 2)
        #expect(rig.deadline.delay == nil)
    }

    @Test func aHiddenPaneStreamAfterAReplyStillWaits() {
        let rig = Rig(hidden: true)
        rig.arrive(answers: true)
        rig.clock += 0.0625
        rig.pacer.delivered()
        // The reply went; a turn's end after it keeps the hidden interval.
        rig.arrive(urgent: true)
        #expect(rig.calls == 1)
        #expect(rig.deadline.delay == .nanoseconds(187_500_000))
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
        rig.arrive(urgent: true)
        rig.pacer.delivered()
        rig.arrive(urgent: true)
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
