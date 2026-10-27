import CmuxNextInputCore
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextBrowser

/// The in-process pump's slices on the frame deadline (plans/cmux-next/chrome-parity/p03-rendering.md,
/// task 116). The fork's static 2 ms slice did not know where the frame was: a pass that began 1 ms
/// before the commit ran 1 ms into it. Each pass now gets the time left before the frame's commit (the
/// target less the measured commit, at most the static slice), none starts with less than 1 ms left or
/// inside a person's input turn, pending input holds the follow-up of a pass that ran its whole slice,
/// and an older fork keeps the static switch. Fake clocks throughout.
@MainActor
@Suite struct CEFPumpFrameDeadlineTests {
    static let refresh: TimeInterval = 1.0 / 120
    /// A 120 Hz frame shown at 100.008 s whose commit takes 3 ms: its commit starts at 100.005 s.
    static let frame = CEFPumpSchedule.Frame(target: 100.008, refresh: refresh, commit: 0.003)
    static let cap: TimeInterval = 0.002

    static func slicer(perCall: Bool = true) -> CEFPumpSchedule.FrameSlicer {
        CEFPumpSchedule.FrameSlicer(cap: cap, perCall: perCall)
    }

    /// The slice of a run, in whole microseconds (rounded down, so the binary fraction of a time like
    /// 1.5 ms may give 1499).
    static func micros(_ decision: CEFPumpSchedule.SliceDecision) -> Int64? {
        guard case .run(let microseconds) = decision else { return nil }
        return microseconds
    }

    // MARK: The slicer

    /// Over three frames, at every 37 us: a slice never ends past the frame's commit deadline, is at
    /// least 1 ms and at most the static slice; a wait ends past that deadline, and the pass then gets
    /// the next frame's time.
    @Test func noSliceCrossesTheDeadline() throws {
        var slicer = Self.slicer()
        var runs = 0
        var waits = 0
        var now = 99.995
        while now < 100.030 {
            let deadline = Self.frame.commitDeadline(after: now)
            switch slicer.decide(now: now, frame: Self.frame, refresh: Self.refresh, inputTurn: false, pageInput: false,
                                 inputPending: { false }) {
            case .run(let microseconds):
                let slice = TimeInterval(try #require(microseconds)) / 1_000_000
                #expect(now + slice <= deadline + 1e-9, "at \(now): \(slice) s runs past the commit deadline \(deadline)")
                #expect(slice >= CEFPumpSchedule.FrameSlicer.floor - 1e-6 && slice <= Self.cap + 1e-9)
                runs += 1
            case .waitForFrame(let until):
                #expect(deadline - now < CEFPumpSchedule.FrameSlicer.floor)
                #expect(until > deadline, "the wait ends past the deadline it could not meet")
                let next = slicer.decide(now: until, frame: Self.frame, refresh: Self.refresh, inputTurn: false,
                                         pageInput: false, inputPending: { false })
                #expect(next == .run(microseconds: 2_000), "the next frame's time: the whole static slice")
                waits += 1
            case .holdForInput:
                Issue.record("no input")
            }
            now += 0.000_037
        }
        #expect(runs > 0 && waits > 0, "both cases seen: \(runs) runs, \(waits) waits")
    }

    @Test func aSliceIsTheTimeLeftBeforeTheCommitUpToTheStaticSlice() {
        var slicer = Self.slicer()
        // 1.5 ms before the commit deadline at 100.005 s.
        let left = Self.micros(slicer.decide(now: 100.0035, frame: Self.frame, refresh: Self.refresh, inputTurn: false,
                                             pageInput: false, inputPending: { false }))
        #expect(left.map { (1_499 ... 1_500).contains($0) } == true, "\(String(describing: left))")
        // 4 ms before it: the static slice.
        #expect(slicer.decide(now: 100.001, frame: Self.frame, refresh: Self.refresh, inputTurn: false, pageInput: false,
                              inputPending: { false }) == .run(microseconds: 2_000))
        // After that commit (the frame is not shown yet): the next frame's commit, one refresh later.
        #expect(slicer.decide(now: 100.0055, frame: Self.frame, refresh: Self.refresh, inputTurn: false, pageInput: false,
                              inputPending: { false }) == .run(microseconds: 2_000))
    }

    @Test func lessThanAMillisecondLeftWaitsForTheNextFrame() {
        var slicer = Self.slicer()
        let decision = slicer.decide(now: 100.0045, frame: Self.frame, refresh: Self.refresh, inputTurn: false,
                                     pageInput: false, inputPending: { false })
        guard case .waitForFrame(let until) = decision else {
            Issue.record("0.5 ms before the commit: \(decision)")
            return
        }
        #expect(abs(until - (100.005 + CEFPumpSchedule.FrameSlicer.slop)) < 1e-9)
    }

    /// No pass starts inside a person's input turn (its dispatch, or its frame not rendered yet): it
    /// waits until the next frame or one refresh, once in a row.
    @Test func noSliceStartsInAnInputTurnAndTheWaitIsOnceInARow() {
        var slicer = Self.slicer()
        let held = slicer.decide(now: 100.001, frame: Self.frame, refresh: Self.refresh, inputTurn: true, pageInput: false,
                                 inputPending: { false })
        #expect(held == .holdForInput(until: 100.008), "until the frame is shown")
        let again = slicer.decide(now: 100.008, frame: Self.frame, refresh: Self.refresh, inputTurn: true, pageInput: false,
                                  inputPending: { false })
        guard case .run = again else {
            Issue.record("a pass waits for input once in a row: \(again)")
            return
        }
        // With the display link idle (no frame), the wait is one refresh.
        let idle = slicer.decide(now: 200, frame: nil, refresh: Self.refresh, inputTurn: true, pageInput: false,
                                 inputPending: { false })
        #expect(idle == .holdForInput(until: 200 + Self.refresh))
    }

    /// Pending input preempts the follow-up of a pass that ran its whole slice (Chromium has work
    /// left); after a short pass pending input is not even read.
    @Test func pendingInputPreemptsTheFollowUpOfALongPass() {
        var slicer = Self.slicer()
        slicer.passEnded(usedWholeSlice: true)
        #expect(slicer.decide(now: 100.001, frame: Self.frame, refresh: Self.refresh, inputTurn: false, pageInput: false,
                              inputPending: { true }) == .holdForInput(until: 100.008))
        _ = slicer.decide(now: 100.008, frame: Self.frame, refresh: Self.refresh, inputTurn: false, pageInput: false,
                          inputPending: { true })
        slicer.passEnded(usedWholeSlice: false)
        var read = false
        let decision = slicer.decide(now: 100.0085, frame: Self.frame, refresh: Self.refresh, inputTurn: false, pageInput: false,
                                     inputPending: { read = true; return true })
        #expect(decision == .run(microseconds: 2_000))
        #expect(!read)
    }

    /// Chromium handles a page's input inside the pump: its pass never waits for input.
    @Test func aPassForAPageInputIsNeverHeldForInput() {
        var slicer = Self.slicer()
        slicer.passEnded(usedWholeSlice: true)
        #expect(slicer.decide(now: 100.001, frame: Self.frame, refresh: Self.refresh, inputTurn: true, pageInput: true,
                              inputPending: { true }) == .run(microseconds: 2_000))
    }

    /// A fork without `cmux_set_message_loop_time_slice` keeps the static switch for every pass, even
    /// with less than a millisecond left; it still waits for an input turn.
    @Test func anOlderForkFallsBackToTheStaticSwitch() {
        var slicer = Self.slicer(perCall: false)
        #expect(slicer.decide(now: 100.0045, frame: Self.frame, refresh: Self.refresh, inputTurn: false, pageInput: false,
                              inputPending: { false }) == .run(microseconds: nil))
        #expect(slicer.decide(now: 100.001, frame: Self.frame, refresh: Self.refresh, inputTurn: true, pageInput: false,
                              inputPending: { false }) == .holdForInput(until: 100.008))
    }

    /// No frame is made (the link idle) or no commit was measured yet: the static switch.
    @Test func noFrameKeepsTheStaticSwitch() {
        var slicer = Self.slicer()
        #expect(slicer.decide(now: 100.0045, frame: nil, refresh: Self.refresh, inputTurn: false, pageInput: false,
                              inputPending: { false }) == .run(microseconds: nil))
        #expect(CEFPumpFrameDeadline.frame(target: 100.008, refresh: Self.refresh, commit: nil) == nil)
        #expect(CEFPumpFrameDeadline.frame(target: nil, refresh: Self.refresh, commit: 0.003) == nil)
    }

    // MARK: The pump

    /// Each pass hands the fork its slice right before `CefDoMessageLoopWork`.
    @Test func thePumpHandsEachPassItsSliceBeforeTheWork() {
        let rig = Rig(now: 100.0035)
        #expect(rig.state.events == ["slice", "work"])
        #expect(rig.state.slices.first.map { (1_499 ... 1_500).contains($0) } == true, "\(rig.state.slices)")
        // The next frame's window: 3.8 ms before its commit, the static slice.
        rig.state.now = 100.0095
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.state.events == ["slice", "work", "slice", "work"])
        #expect(rig.state.slices.last == 2_000)
    }

    /// Less than a millisecond left: the timer is armed exactly at the end of the wait, no pass runs
    /// before it, and the pass that runs then has the next frame's slice.
    @Test func aWaitArmsTheTimerExactlyAndThePassRunsThen() throws {
        let rig = Rig(now: 100.0045)
        #expect(rig.state.events.isEmpty, "less than 1 ms before the commit: no pass")
        let armed = try #require(rig.timer.armed)
        #expect(abs(armed - (0.0005 + CEFPumpSchedule.FrameSlicer.slop)) < 1e-9)
        #expect(rig.timer.tolerance == 0)
        #expect(rig.pump.stats.frameDeadlineWaits == 1)
        rig.state.now = 100.005 + CEFPumpSchedule.FrameSlicer.slop
        rig.timer.fire()
        #expect(rig.state.events == ["slice", "work"])
        #expect(rig.state.slices == [2_000])
    }

    /// An input turn holds the pass once, until the frame is shown.
    @Test func anInputTurnHoldsThePassUntilTheFrame() throws {
        let rig = Rig(now: 100.001, inputTurn: true)
        #expect(rig.state.events.isEmpty)
        #expect(rig.pump.stats.frameInputHolds == 1)
        let armed = try #require(rig.timer.armed)
        #expect(abs(armed - 0.007) < 1e-9)
        rig.state.now = 100.008
        rig.timer.fire()
        #expect(rig.state.events == ["slice", "work"])
        #expect(rig.state.slices == [2_000])
    }

    /// A pass that ran its whole per-call slice counts as long, and its follow-up waits for pending input.
    @Test func aPassThatRanItsSliceIsLongAndItsFollowUpWaitsForInput() {
        let rig = Rig(now: 100.0035, passLength: 0.0016)
        #expect(rig.state.events == ["slice", "work"])
        #expect(rig.pump.stats.longWorkRuns == 1, "1.6 ms ran its 1.5 ms slice, under the static 2 ms")
        rig.pending.isPending = true
        rig.state.now = 100.0055
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.state.events.count == 2, "the follow-up waits while input is pending")
        #expect(rig.pump.stats.frameInputHolds == 1)
    }

    /// An older fork: no slice is set, and the static one judges a long pass.
    @Test func anOlderForkSetsNoSlice() {
        let rig = Rig(now: 100.0045, perCall: false, passLength: 0.0016)
        #expect(rig.state.events == ["work"])
        #expect(rig.pump.stats.longWorkRuns == 0)
        #expect(rig.pump.stats.frameDeadlineWaits == 0)
    }

    // MARK: One wait for input

    /// Both features on: the input policy held a pass that follows a long one while input was pending,
    /// and that hold reached its bound. The frame deadline does not hold it for input again: the pass
    /// runs within one refresh of its first hold, not about two.
    @Test func theInputPolicysHoldIsThePasssOnlyInputWait() throws {
        let rig = Rig(now: 100.0035, passLength: 0.0016, inputPolicy: true)
        #expect(rig.pump.stats.longWorkRuns == 1)
        rig.state.passLength = 0
        rig.pending.isPending = true
        let firstHold = 100.0055
        rig.state.now = firstHold
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.state.events.count == 2, "the policy holds the pass while input is pending")
        let armed = try #require(rig.timer.armed)
        #expect(abs(armed - 0.0025) < 1e-9, "until the frame at 100.008")
        rig.state.now = firstHold + armed
        rig.timer.fire()
        #expect(rig.state.events == ["slice", "work", "slice", "work"], "the bound ran out: it runs, not held again")
        #expect(rig.state.now <= firstHold + Self.refresh)
        #expect(rig.pump.stats.frameInputHolds == 0)
        #expect(rig.pump.stats.passesWhileInputPending.boundExpired == 1)
    }

    /// The other way round: the frame deadline held a pass for an input turn; when it is decided again
    /// with input pending, the input policy does not start a second wait.
    @Test func theFrameDeadlinesInputHoldIsThePasssOnlyInputWait() throws {
        let rig = Rig(now: 100.001, inputTurn: true, inputPolicy: true)
        #expect(rig.state.events.isEmpty)
        #expect(rig.pump.stats.frameInputHolds == 1)
        rig.pending.isPending = true
        rig.state.now = 100.001 + (try #require(rig.timer.armed))
        rig.timer.fire()
        #expect(rig.state.events == ["slice", "work"])
        #expect(rig.pump.stats.deferredForInput == 0)
    }

    // MARK: Page input ends an input hold

    /// A pass held for an input turn: a scroll or a click AppKit delivers to a Chromium page ends the
    /// hold, with the input policy on or off, and the next fire runs the pass that serves it.
    @Test(arguments: [false, true])
    func aPageInputEndsAnInputHold(inputPolicy: Bool) throws {
        let rig = Rig(now: 100.001, inputTurn: true, inputPolicy: inputPolicy)
        #expect(rig.state.events.isEmpty)
        #expect(rig.timer.armed.map { abs($0 - 0.007) < 1e-9 } == true, "held until the frame")
        rig.state.now = 100.002
        rig.dispatches.end(.chromiumPage)
        #expect(rig.timer.armed == 0, "armed for the next run loop pass")
        rig.timer.fire()
        #expect(rig.state.events == ["slice", "work"])
    }

    /// A wait for the frame stays: less than 1 ms is left before the commit.
    @Test func aPageInputKeepsAFrameWait() throws {
        let rig = Rig(now: 100.0045)
        #expect(rig.pump.stats.frameDeadlineWaits == 1)
        rig.dispatches.end(.chromiumPage)
        let armed = try #require(rig.timer.armed)
        #expect(abs(armed - (0.0005 + CEFPumpSchedule.FrameSlicer.slop)) < 1e-9)
    }

    // MARK: Keyboard focus

    /// A browser pane is key, and cmux consumed a shortcut (Cmd-D, Cmd-T): the input turn is open and
    /// the dispatch went to cmux. Keyboard focus does not exempt the turn.
    @Test func aPageWithTheKeyboardDoesNotExemptAnInputTurnForCmux() {
        let probe = Probe(pageHasKeyboard: true)
        probe.state.inputTurn = true
        probe.dispatches.end(.other)
        #expect(probe.deadline.decide(now: 100.001, servesPage: false) == .holdForInput(until: 100.008))
    }

    /// With a page key, pending keys go to the page and hold nothing; pending pointer input after a long
    /// pass still holds, as in the input policy.
    @Test func aPageWithTheKeyboardExemptsOnlyPendingKeys() {
        let probe = Probe(pageHasKeyboard: true)
        probe.deadline.passEnded(usedWholeSlice: true)
        probe.pending.isPending = true
        #expect(probe.deadline.decide(now: 100.001, servesPage: false) == .run(microseconds: 2_000))
        probe.pending.pointerPending = true
        #expect(probe.deadline.decide(now: 100.001, servesPage: false) == .holdForInput(until: 100.008))
    }

    // MARK: Plan apply

    /// A plan applied with no input turn (a CLI, socket or agent split): no slice starts before its commit.
    @Test func aPlanApplyHoldsTheSliceWithNoInputTurn() throws {
        var slicer = Self.slicer()
        #expect(slicer.decide(now: 100.001, frame: Self.frame, refresh: Self.refresh, inputTurn: false, planApply: true,
                              pageInput: false, inputPending: { false }) == .holdForInput(until: 100.008))
        let rig = Rig(now: 100.001, planApply: true)
        #expect(rig.state.events.isEmpty)
        #expect(rig.pump.stats.frameInputHolds == 1)
        rig.state.planApply = false
        rig.state.now = 100.001 + (try #require(rig.timer.armed))
        rig.timer.fire()
        #expect(rig.state.events == ["slice", "work"])
    }

    // MARK: Rig

    /// What the pump's closures read and record.
    final class State {
        var now: TimeInterval
        var inputTurn: Bool
        var planApply: Bool
        var pageHasKeyboard: Bool
        var passLength: TimeInterval
        var events: [String] = []
        var slices: [Int64] = []

        init(now: TimeInterval, inputTurn: Bool, planApply: Bool = false, pageHasKeyboard: Bool = false, passLength: TimeInterval) {
            self.now = now
            self.inputTurn = inputTurn
            self.planApply = planApply
            self.pageHasKeyboard = pageHasKeyboard
            self.passLength = passLength
        }
    }

    /// A frame deadline on ``CEFPumpFrameDeadlineTests/frame`` reading `state` and `pending`.
    static func frameDeadline(state: State, pending: Pending, dispatches: Dispatches, perCall: Bool = true) -> CEFPumpFrameDeadline {
        let frame = Self.frame
        let seams = CEFPumpFrameSeams(frameTarget: { frame.target }, refreshInterval: { frame.refresh },
                                      commitEstimate: { frame.commit }, inputTurnOpen: { state.inputTurn },
                                      planApplyOpen: { state.planApply }, pending: pending)
        let setSlice: ((Int64) -> Void)? = perCall ? { state.events.append("slice"); state.slices.append($0) } : nil
        return CEFPumpFrameDeadline(seams: seams, cap: Self.cap, setSlice: setSlice, pageHasKeyboard: { state.pageHasKeyboard },
                                    dispatches: dispatches, clock: { state.now })
    }

    /// A frame deadline alone, asked by hand.
    final class Probe {
        let state: State
        let pending = Pending()
        let dispatches = Dispatches()
        let deadline: CEFPumpFrameDeadline

        init(pageHasKeyboard: Bool = false) {
            let state = State(now: 100.001, inputTurn: false, pageHasKeyboard: pageHasKeyboard, passLength: 0)
            self.state = state
            deadline = CEFPumpFrameDeadlineTests.frameDeadline(state: state, pending: pending, dispatches: dispatches)
        }
    }

    /// A started pump with a frame deadline on ``CEFPumpFrameDeadlineTests/frame`` (and, with
    /// `inputPolicy`, the input policy on the same input); its start's pass is decided at `now`.
    final class Rig {
        let state: State
        let timer = Timer()
        let pending = Pending()
        let dispatches = Dispatches()
        let pump: CEFMessagePump

        init(now: TimeInterval, perCall: Bool = true, inputTurn: Bool = false, planApply: Bool = false,
             passLength: TimeInterval = 0, inputPolicy: Bool = false) {
            let state = State(now: now, inputTurn: inputTurn, planApply: planApply, passLength: passLength)
            self.state = state
            pump = CEFMessagePump(work: {
                state.events.append("work")
                state.now += state.passLength
            }, timer: timer, timeSlice: CEFPumpFrameDeadlineTests.cap, clock: { state.now }, ledger: WakeupLedger())
            if inputPolicy {
                let frame = CEFPumpFrameDeadlineTests.frame
                pump.setInputPolicy(CEFPumpInputPolicy(pending: pending, dispatches: dispatches, refreshInterval: { frame.refresh },
                                                       frameTarget: { frame.target }))
            }
            pump.setFrameDeadline(CEFPumpFrameDeadlineTests.frameDeadline(state: state, pending: pending, dispatches: dispatches,
                                                                         perCall: perCall))
            pump.start()
            timer.fire()
        }
    }

    final class Pending: InputPendingSource {
        var isPending = false
        /// Pending input includes a mouse button, a scroll begin or a drag.
        var pointerPending = false
        func hasPendingInput(uptime: TimeInterval) -> Bool { isPending || pointerPending }
        func hasPendingPointerInput(uptime: TimeInterval) -> Bool { pointerPending }
    }

    /// The end of each input's dispatch, for every follower (the input policy and the frame deadline).
    final class Dispatches: CEFPumpInputDispatches {
        private var handlers: [(flag: InputSubscriptionFlag, handler: (InputTarget) -> Void)] = []

        func observeDispatchEnd(_ handler: @escaping (InputTarget) -> Void) -> InputSubscription {
            let flag = InputSubscriptionFlag()
            handlers.append((flag, handler))
            return InputSubscription(flag: flag)
        }

        func end(_ target: InputTarget) {
            for entry in handlers where !entry.flag.isCancelled { entry.handler(target) }
        }
    }

    /// The pump's timer, fired by hand.
    final class Timer: CEFPumpTimer {
        var onFire: (() -> Void)?
        var armed: TimeInterval?
        var tolerance: TimeInterval?
        func arm(after delay: TimeInterval, tolerance: TimeInterval) {
            armed = delay
            self.tolerance = tolerance
        }
        func disarm() { armed = nil }
        func invalidate() { armed = nil }
        func fire() {
            armed = nil
            onFire?()
        }
    }
}
