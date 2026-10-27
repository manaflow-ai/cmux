import AppKit
import CmuxNextInputCore
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextBrowser

/// The CEF pump on the main-thread task board (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// task 048): each pass is a `cef.pump` task, in the input class while a page has the keyboard or a
/// page input's ack may be due and the frame class otherwise. Pending keys to a focused page and input
/// after a page input never hold a pass; pending pointer input still does. Attribution only: no class
/// is budgeted, none is chosen by visibility, and a nested run loop a pass runs is not its time.
@MainActor
@Suite(.serialized) struct CEFPumpBoardTests {
    typealias Timer = CEFPumpInputYieldTests.Timer
    static let refresh = CEFPumpInputYieldTests.refresh

    @Test func theClassIsInputOnlyForAFocusedPageOrRecentPageInput() {
        #expect(CEFPumpSchedule.workClass(pageHasFocus: false, pageInputRecent: false) == .frame)
        #expect(CEFPumpSchedule.workClass(pageHasFocus: true, pageInputRecent: false) == .input)
        #expect(CEFPumpSchedule.workClass(pageHasFocus: false, pageInputRecent: true) == .input)
        #expect(!CEFPumpSchedule.workClass(pageHasFocus: false, pageInputRecent: false).isBudgeted)
    }

    /// A page input counts until a pass began after it and one refresh passed since its dispatch.
    @Test func aPageInputIsRecentUntilAPassAndARefreshFollowedIt() {
        var input = CEFPumpSchedule.RecentPageInput()
        #expect(!input.isRecent(at: 10, refresh: 0.01))
        input.dispatched(at: 10)
        #expect(input.isRecent(at: 20, refresh: 0.01), "no pass has run since: its ack is still due")
        input.passBegan()
        #expect(input.isRecent(at: 10.005, refresh: 0.01), "the renderer's ack may come back to a later pass")
        #expect(!input.isRecent(at: 10.01, refresh: 0.01))
        input.dispatched(at: 11)
        #expect(input.isRecent(at: 12, refresh: 0.01), "an input dispatched during a pass waits for the next")
    }

    /// Acceptance: pump passes show in `debug.main_budget owners`, under `cef.pump`.
    @Test func passesShowInTheOwnersLedger() throws {
        let rig = Rig()
        rig.pass()
        rig.focused = true
        rig.pass()
        #expect(rig.passes == 3)
        let frame = try #require(rig.owner(.frame))
        let input = try #require(rig.owner(.input))
        #expect(frame.tasks == 2, "the start's pass and the unfocused one")
        #expect(input.tasks == 1)
        #expect(rig.budget.board.running == nil, "the pass's task ended with it")
    }

    /// Acceptance: 0 deferrals for the keys a focused page gets; each such pass is counted.
    @Test func aFocusedPageIsNeverDeferredForPendingKeys() {
        let rig = Rig()
        rig.focused = true
        rig.pending.keys = true
        for _ in 0..<5 { rig.pass() }
        #expect(rig.passes == 6)
        #expect(rig.pump.stats.deferredForInput == 0)
        #expect(rig.pump.stats.passesWhileInputPending[.chromiumPage] == 5, "debug.input sees every pass that ran ahead of a key")
        // Focus moves to cmux (the omnibar): the policy holds the next pass for the pending key.
        rig.focused = false
        rig.pass()
        #expect(rig.passes == 6)
        #expect(rig.pump.stats.deferredForInput == 1)
    }

    /// A scroll, click or drag goes to the view under the pointer (a terminal, the sidebar), not to
    /// the key page: it holds the pass as without a focused page.
    @Test func aFocusedPageStillWaitsForPendingPointerInput() {
        let rig = Rig()
        rig.focused = true
        rig.pending.pointer = true
        rig.pass()
        #expect(rig.passes == 1, "held for the pending scroll")
        #expect(rig.pump.stats.deferredForInput == 1)
        #expect(rig.pump.stats.passesWhileInputPending[.chromiumPage] == 0)
        // Its dispatch went to a plain window: the held pass runs at the next run loop pass.
        rig.pending.pointer = false
        rig.dispatches.end(.other)
        rig.timer.fire()
        #expect(rig.passes == 2)
    }

    /// After an input AppKit delivered to a page, the passes in the next refresh are input tasks and
    /// pending input holds none of them: one of them handles the renderer's ack. Then the input
    /// class ends and pending input holds a pass again.
    @Test func pageInputKeepsTheInputClassForARefresh() {
        let rig = Rig()
        rig.dispatches.end(.chromiumPage)
        rig.pending.pointer = true
        rig.pass()
        rig.clock.seconds += Self.refresh / 2
        rig.pass()
        #expect(rig.passes == 3, "the page's ack is handled inside the pump: no hold")
        #expect(rig.pump.stats.deferredForInput == 0)
        #expect(rig.pump.stats.passesWhileInputPending[.chromiumPage] == 2, "each counted under the page")
        #expect(rig.owner(.input)?.tasks == 2)
        rig.clock.seconds += Self.refresh
        rig.pass()
        #expect(rig.passes == 3)
        #expect(rig.pump.stats.deferredForInput == 1)
        // A terminal's key is no page input.
        rig.pending.pointer = false
        rig.dispatches.end(.terminal)
        rig.timer.fire()
        #expect(rig.passes == 4)
        #expect(rig.owner(.input)?.tasks == 2)
        #expect(rig.owner(.frame)?.tasks == 2)
    }

    /// Without an input policy the board follows the dispatches itself.
    @Test func withoutAPolicyTheBoardFollowsPageInput() {
        let rig = Rig(policy: false)
        #expect(rig.boardDispatches.observers == 1)
        rig.boardDispatches.end(.chromiumPage)
        rig.pass()
        #expect(rig.owner(.input)?.tasks == 1)
        rig.pump.stop()
        #expect(rig.boardDispatches.isCancelled)
    }

    /// With a policy the pump has one dispatch follower, the policy's, and the board takes page input
    /// from it.
    @Test func withAPolicyThePumpFollowsTheDispatchesOnce() {
        let rig = Rig()
        #expect(rig.boardDispatches.observers == 0)
        #expect(rig.dispatches.observers == 1)
    }

    /// Acceptance: a hidden tab's CDP round trip (a burst of passes, no page focused, no input) runs
    /// pass for pass as without the board: the board holds nothing and runs each one as a frame task.
    @Test func aHiddenTabsCDPRoundTripIsUnchanged() {
        let onBoard = Rig()
        let plain = Rig(board: false)
        for _ in 0..<8 {
            onBoard.pump.request(milliseconds: 0)
            plain.pump.request(milliseconds: 0)
            #expect(onBoard.timer.armed == plain.timer.armed)
            onBoard.timer.fire()
            plain.timer.fire()
        }
        #expect(onBoard.passes == 9)
        #expect(plain.passes == 9)
        #expect(onBoard.pump.stats == plain.pump.stats)
        #expect(onBoard.owner(.frame)?.tasks == 9)
    }

    /// A late frame holds an unfocused pump's second pass; a focused page's passes are never held.
    @Test func aLateFrameNeverHoldsAFocusedPagesPass() {
        let media = CEFMessagePumpStarvationTests.Media()
        let window = FrameScheduler.testing(mediaTime: media.read) { _ in CEFMessagePumpStarvationTests.Link() }
        let starvation = RenderStarvationGuard(holdsWork: true, visibility: CEFMessagePumpStarvationTests.Shown(),
                                               mediaTime: media.read)
        starvation.watch(window)
        let spring = FrameClient(owner: "spring", on: window) { _ in true }
        let timer = Timer()
        var passes = 0
        let focused = Flag(true)
        let budget = MainFrameBudget()
        let board = CEFPumpBoard(budget: budget, dispatches: nil, pageHasFocus: { focused.value })
        let pump = CEFMessagePump(work: { passes += 1 }, timer: timer, clock: { media.now }, ledger: WakeupLedger(),
                                  starvation: starvation, board: board)
        pump.start()
        timer.fire()
        spring.activate()
        window.frameDidFire(timestamp: media.now, refreshInterval: 1.0 / 60)
        media.now += 0.2
        for _ in 0..<3 {
            pump.scheduleNow()
            timer.fire()
        }
        #expect(passes == 4, "every pass of a focused page runs in the late frame")
        #expect(pump.stats.lateFrameHolds == 0)
        focused.value = false
        pump.scheduleNow()
        timer.fire()
        #expect(passes == 5, "the late frame's one unfocused pass")
        pump.scheduleNow()
        timer.fire()
        #expect(passes == 5, "the next waits for the late link")
        #expect(pump.stats.lateFrameHolds == 1)
        spring.deactivate()
        pump.stop()
    }

    /// A pass that runs a context menu (a nested run loop inside `CefDoMessageLoopWork`): the menu's
    /// time is not the pass's, and no task is named while the menu runs.
    @Test func aNestedLoopInAPassIsNotThePassesTime() throws {
        let rig = Rig()
        var runningInMenu: MainTaskBoard.Task?
        rig.work = {
            rig.clock.seconds += 0.001
            rig.budget.turns.loopEntered()
            runningInMenu = rig.budget.board.running
            rig.clock.seconds += 5
            rig.budget.turns.loopExited()
            rig.clock.seconds += 0.001
        }
        rig.pass()
        #expect(rig.passes == 2)
        #expect(runningInMenu == nil, "the watchdog names no pump pass for a stall in the menu")
        let frame = try #require(rig.owner(.frame))
        #expect(frame.tasks == 2)
        #expect(frame.runTotalNanos == 2_000_000, "the pass's own 2 ms, not the menu's 5 s")
        #expect(frame.run.maxNanos < 10_000_000)
        #expect(rig.budget.turns.snapshot().maxTaskNanos == 2_000_000)
    }

    /// The app's focus check: a key page window (`CefNSWindow`) has the keyboard, a cmux window does
    /// not; the pump's dispatch follower uses the same classifier.
    @Test func theKeyWindowCheckFindsAPageWindow() throws {
        let windows = try CEFPumpInputYieldTests.Windows()
        defer { windows.close() }
        let key = KeyWindow()
        var lookups = 0
        let pages = ChromiumPageWindowClassifier(pageWindowClass: {
            lookups += 1
            return windows.pageClass
        })
        let focused = CEFPumpBoard.keyWindowIsPage(keyWindow: { key.window }, pages: pages)
        #expect(!focused())
        key.window = windows.plain
        #expect(!focused())
        key.window = windows.page
        #expect(focused())
        #expect(pages.isPage(windows.page))
        #expect(lookups == 1, "the class is looked up once")
    }

    // MARK: Doubles

    /// Page focus the test changes while the board reads it.
    final class Flag {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    /// The key window the test changes while the focus check reads it.
    final class KeyWindow {
        var window: NSWindow?
    }

    /// Pending keys and pointer input, set apart.
    final class Pending: InputPendingSource {
        var keys = false
        var pointer = false
        func hasPendingInput(uptime: TimeInterval) -> Bool { keys || pointer }
        func hasPendingPointerInput(uptime: TimeInterval) -> Bool { pointer }
    }

    /// The pump's clock (uptime seconds) and the budget's (its nanoseconds), moved by hand.
    final class Clock {
        var seconds: TimeInterval = 100
        var nanos: UInt64 { UInt64((seconds * 1e9).rounded()) }
    }

    /// Input dispatch ends the test sends, with the count of followers.
    final class Dispatches: CEFPumpInputDispatches {
        private var handler: ((InputTarget) -> Void)?
        private var subscription: InputSubscription?
        private(set) var observers = 0

        var isCancelled: Bool { subscription?.isCancelled ?? true }

        func observeDispatchEnd(_ handler: @escaping (InputTarget) -> Void) -> InputSubscription {
            observers += 1
            self.handler = handler
            let subscription = InputSubscription(flag: InputSubscriptionFlag())
            self.subscription = subscription
            return subscription
        }

        func end(_ target: InputTarget) {
            guard !isCancelled else { return }
            handler?(target)
        }
    }

    @MainActor
    final class Rig {
        let clock: Clock
        let timer = Timer()
        let pending = Pending()
        let dispatches = Dispatches()
        let boardDispatches = Dispatches()
        let budget: MainFrameBudget
        var focused = false
        var passes = 0
        /// What each pass does besides counting.
        var work: () -> Void = {}
        private(set) var pump: CEFMessagePump!

        init(policy: Bool = true, board onBoard: Bool = true) {
            let clock = Clock()
            self.clock = clock
            budget = MainFrameBudget(uptimeNanos: { clock.nanos })
            let board = onBoard
                ? CEFPumpBoard(budget: budget, dispatches: boardDispatches, pageHasFocus: { [unowned self] in self.focused },
                               refreshInterval: { CEFPumpBoardTests.refresh })
                : nil
            pump = CEFMessagePump(work: { [unowned self] in
                self.passes += 1
                self.work()
            }, timer: timer, clock: { clock.seconds }, ledger: WakeupLedger(), board: board)
            if policy {
                pump.setInputPolicy(CEFPumpInputPolicy(pending: pending, dispatches: dispatches,
                                                       refreshInterval: { CEFPumpBoardTests.refresh }))
            }
            pump.start()
            timer.fire()
        }

        /// One immediate request and its timer fire.
        func pass() {
            pump.scheduleNow()
            timer.fire()
        }

        /// The `cef.pump` row of `workClass` in the owners ledger.
        func owner(_ workClass: MainWorkClass) -> MainOwnerLedger.Owner? {
            budget.board.ownerSnapshot().owners.first { $0.owner == CEFPumpBoard.ownerName && $0.workClass == workClass }
        }
    }
}
