import AppKit
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A chat whose page the page lifecycle froze gets no bridge call, no fallback deadline and no
/// display-frame request from its transport, whatever arrives, and one call when it thaws
/// (plans/cmux-next/chrome-parity/p13-webui.md, task 070). Before, a frozen hidden chat still took a
/// call at most every ``AgentPaneFramePacer/hiddenInterval`` for every reply or turn end, each one a
/// deadline wake and a push into a page that could not run it.
@Suite(.serialized)
@MainActor
struct AgentPaneFramePacerTests {
    final class Ticks: AgentPaneFrameTicks {
        var onTick: (@MainActor () -> Void)?
        var activations = 0
        var active = false
        func activate() {
            activations += 1
            active = true
        }
        func deactivate() { active = false }
        func tick() { onTick?() }
    }

    final class Deadline: AgentPaneFallbackDeadline {
        var scheduled = 0
        var action: (@MainActor @Sendable () -> Void)?
        func schedule(after delay: Duration, _ action: @escaping @MainActor @Sendable () -> Void) {
            scheduled += 1
            self.action = action
        }
        func cancel() { action = nil }
        func fire() {
            let action = action
            self.action = nil
            action?()
        }
    }

    final class Rig {
        var clock: TimeInterval = 100
        var hidden: Bool
        var turns: [@MainActor @Sendable () -> Void] = []
        var calls = 0
        let ticks = Ticks()
        let deadline = Deadline()
        lazy var pacer = AgentPaneFramePacer(
            frames: ticks, fallback: deadline, now: { [unowned self] in self.clock },
            nextTurn: { [unowned self] work in self.turns.append(work) },
            isHidden: { [unowned self] in self.hidden })

        init(hidden: Bool) { self.hidden = hidden }

        /// Frames arrive (`urgent`: the page waits on them); one call delivers them all.
        func arrive(urgent: Bool = false) {
            pacer.schedule(urgent: urgent) { [unowned self] in
                self.calls += 1
                return AgentPaneFlush(delivered: true, more: false)
            }
        }

        /// Runs what the pacer left for the next turn.
        func runTurns() {
            let work = turns
            turns.removeAll()
            for item in work { item() }
        }

        /// Every wake the pacer asked for since `scheduled` deadlines and `activations` frame requests.
        func wakes(since start: (deadlines: Int, frames: Int)) -> Int {
            deadline.scheduled - start.deadlines + ticks.activations - start.frames
        }
    }

    /// 60 s of a frozen chat's traffic at 16 frames a second, the page waiting on every fourth: replies
    /// and turn ends, which a hidden pane gets every 0.25 s.
    private func freezeAndStream(_ rig: Rig) -> Int {
        rig.pacer.pageDidFreeze()
        let start = (deadlines: rig.deadline.scheduled, frames: rig.ticks.activations)
        for frame in 0..<960 {
            rig.arrive(urgent: frame % 4 == 0)
            rig.clock += 0.0625
            rig.deadline.fire()
            rig.ticks.tick()
            rig.runTurns()
            rig.pacer.delivered()
        }
        return rig.wakes(since: start)
    }

    @Test func aFrozenHiddenChatGetsNoCallAndNoDeadlineForAMinuteAndOneCallOnThaw() {
        let rig = Rig(hidden: true)
        let wakes = freezeAndStream(rig)
        #expect(rig.calls == 0, "a frozen page was called \(rig.calls) times")
        #expect(wakes == 0, "a frozen page's pacer armed \(wakes) deadlines or frame requests")
        #expect(!rig.ticks.active)
        // The thaw of a show runs before the page is visible: the pane still counts hidden, and the
        // frames go anyway, in one call.
        rig.pacer.pageDidThaw()
        #expect(rig.calls == 1)
        // Hidden after the thaw: a streaming update waits for the show again.
        rig.clock += 1
        rig.pacer.delivered()
        rig.arrive()
        #expect(rig.calls == 1)
        #expect(rig.pacer.held)
    }

    @Test func aFrozenVisiblePanesPacerIsSilentToo() {
        let rig = Rig(hidden: false)
        let wakes = freezeAndStream(rig)
        #expect(rig.calls == 0)
        #expect(wakes == 0)
        rig.pacer.pageDidThaw()
        #expect(rig.calls == 1)
    }

    @Test func theFreezeCancelsTheHiddenIntervalDeadline() {
        let rig = Rig(hidden: true)
        rig.arrive(urgent: true)
        rig.clock += 0.0625
        rig.pacer.delivered()
        rig.arrive(urgent: true)
        #expect(rig.pacer.waitingWhileHidden)
        #expect(rig.deadline.action != nil)
        rig.pacer.pageDidFreeze()
        #expect(rig.deadline.action == nil, "the freeze left the hidden-interval deadline armed")
        #expect(!rig.pacer.waitingWhileHidden)
        rig.pacer.pageDidThaw()
        #expect(rig.calls == 2)
    }

    @Test func theFreezeCancelsTheDisplayFrameWait() {
        let rig = Rig(hidden: false)
        rig.arrive()
        rig.arrive()
        rig.pacer.delivered() // within one frame of the call: the rest waits for the next display frame
        #expect(rig.pacer.waitingForFrame)
        rig.pacer.pageDidFreeze()
        #expect(!rig.ticks.active)
        #expect(rig.deadline.action == nil)
        rig.ticks.tick()
        #expect(rig.calls == 1)
        rig.pacer.pageDidThaw()
        #expect(rig.calls == 2)
    }

    @Test func aCallInFlightAtTheFreezeStartsNoOtherAndTheThawCallFollowsIt() {
        let rig = Rig(hidden: true)
        rig.arrive(urgent: true)
        #expect(rig.calls == 1)
        rig.pacer.pageDidFreeze()
        rig.arrive()
        rig.clock += 1
        rig.pacer.delivered()
        #expect(rig.calls == 1)
        #expect(rig.deadline.action == nil)
        rig.pacer.pageDidThaw()
        #expect(rig.calls == 2)
    }

    @Test func aThawWhileTheEarlierCallRunsSendsWhenItIsDone() {
        let rig = Rig(hidden: true)
        rig.arrive(urgent: true)
        rig.pacer.pageDidFreeze()
        rig.arrive()
        // Thawed while the call from before the freeze is still in flight: it goes first.
        rig.pacer.pageDidThaw()
        #expect(rig.calls == 1)
        rig.clock += 1
        rig.pacer.delivered()
        #expect(rig.calls == 2, "the thaw's call did not follow the call in flight")
    }

    @Test func aThawWithNothingWaitingMakesNoCallAndLeavesTheHiddenHoldOn() {
        let rig = Rig(hidden: true)
        rig.pacer.pageDidFreeze()
        rig.pacer.pageDidThaw()
        #expect(rig.calls == 0)
        rig.arrive()
        #expect(rig.calls == 0)
        #expect(rig.pacer.held)
    }

    @Test func aThawDuringACallWithNothingWaitingLeavesTheHiddenHoldOn() {
        let rig = Rig(hidden: true)
        rig.arrive(urgent: true)
        #expect(rig.calls == 1)
        rig.pacer.pageDidFreeze()
        rig.pacer.pageDidThaw()
        rig.pacer.delivered()
        rig.clock += 60
        rig.arrive()
        #expect(rig.calls == 1, "a stale thaw let a streaming frame wake the hidden page")
        #expect(rig.pacer.held)
    }

    @Test func aPaneThatShowsWhileFrozenRunsAgain() {
        let rig = Rig(hidden: true)
        rig.pacer.pageDidFreeze()
        rig.arrive()
        rig.pacer.visibilityChanged()
        #expect(rig.calls == 0)
        // A page that shows is never frozen: the page view thaws first, whichever path showed it.
        rig.hidden = false
        rig.pacer.visibilityChanged()
        #expect(!rig.pacer.frozen)
        #expect(rig.calls == 1)
    }

    @Test func theProbeIsNotSeenOutOfAWindowOrHidden() {
        let probe = AgentPaneVisibilityProbe(frame: .zero)
        var changes = 0
        probe.onChange = { changes += 1 }
        #expect(!probe.isSeen)
        probe.viewDidHide()
        probe.viewDidUnhide()
        #expect(!probe.isSeen, "a probe in no window counted as seen")
        #expect(changes == 0)
    }
}
