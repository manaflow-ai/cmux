import AppKit
import CmuxNextInputCore
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
@testable import CmuxNextBrowser

/// The CEF pump on the main-thread task board (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// task 048): each pass is a `cef.pump` task, in the input class while a page has the keyboard or an
/// unacked input and the frame class otherwise, and in the input class no pending input and no late
/// frame holds it. Attribution only: no class is budgeted and none is chosen by visibility.
@MainActor
@Suite(.serialized) struct CEFPumpBoardTests {
    typealias Timer = CEFPumpInputYieldTests.Timer
    typealias Pending = CEFPumpInputYieldTests.Pending
    typealias Dispatches = CEFPumpInputYieldTests.Dispatches

    @Test func theClassIsInputOnlyForAFocusedPageOrUnackedInput() {
        #expect(CEFPumpSchedule.workClass(pageHasFocus: false, pageInputUnacked: false) == .frame)
        #expect(CEFPumpSchedule.workClass(pageHasFocus: true, pageInputUnacked: false) == .input)
        #expect(CEFPumpSchedule.workClass(pageHasFocus: false, pageInputUnacked: true) == .input)
        #expect(!CEFPumpSchedule.workClass(pageHasFocus: false, pageInputUnacked: false).isBudgeted)
    }

    /// Acceptance: pump passes show in `debug.main_budget owners`, under `cef.pump`.
    @Test func passesShowInTheOwnersLedger() throws {
        let rig = Rig()
        rig.pump.scheduleNow()
        rig.timer.fire()
        rig.focused = true
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.passes == 3)
        let owners = rig.budget.board.ownerSnapshot().owners.filter { $0.owner == CEFPumpBoard.ownerName }
        let frame = try #require(owners.first { $0.workClass == .frame })
        let input = try #require(owners.first { $0.workClass == .input })
        #expect(frame.tasks == 2, "the start's pass and the unfocused one")
        #expect(input.tasks == 1)
        #expect(rig.budget.board.running == nil, "the pass's task ended with it")
    }

    /// Acceptance: 0 deferrals while a page has focus, whatever input is pending.
    @Test func aFocusedPageIsNeverDeferredForInput() {
        let rig = Rig()
        rig.focused = true
        rig.pending.isPending = true
        for _ in 0..<5 {
            rig.pump.scheduleNow()
            rig.timer.fire()
        }
        #expect(rig.passes == 6)
        #expect(rig.pump.stats.deferredForInput == 0)
        // Focus moves to cmux (the omnibar): the policy holds the next pass for the pending key.
        rig.focused = false
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.passes == 6)
        #expect(rig.pump.stats.deferredForInput == 1)
    }

    /// An input AppKit delivered to a page is unacked until the next pass: that pass is an input
    /// task and no pending input holds it; the one after is a frame task again.
    @Test func unackedPageInputMakesTheNextPassAnInputTask() throws {
        let rig = Rig()
        rig.boardDispatches.end(.chromiumPage)
        rig.pending.isPending = true
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.passes == 2, "the page's input is acked inside the pump: no hold")
        #expect(rig.pump.stats.deferredForInput == 0)
        rig.pending.isPending = false
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.passes == 3)
        let owners = rig.budget.board.ownerSnapshot().owners.filter { $0.owner == CEFPumpBoard.ownerName }
        #expect(owners.first { $0.workClass == .input }?.tasks == 1)
        #expect(owners.first { $0.workClass == .frame }?.tasks == 2)
        // A terminal's key is no page input.
        rig.boardDispatches.end(.terminal)
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.budget.board.ownerSnapshot().owners.first { $0.owner == CEFPumpBoard.ownerName && $0.workClass == .input }?.tasks == 1)
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

    @Test func stopEndsTheBoardsDispatchSubscription() {
        let rig = Rig()
        #expect(!rig.boardDispatches.isCancelled)
        rig.pump.stop()
        #expect(rig.boardDispatches.isCancelled)
    }

    /// The app's focus check: a key page window (`CefNSWindow`) has the keyboard, a cmux window does not.
    @Test func theKeyWindowCheckFindsAPageWindow() throws {
        let windows = try CEFPumpInputYieldTests.Windows()
        defer { windows.close() }
        let key = KeyWindow()
        var lookups = 0
        let focused = CEFPumpBoard.keyWindowIsPage(keyWindow: { key.window }, pageWindowClass: {
            lookups += 1
            return windows.pageClass
        })
        #expect(!focused())
        key.window = windows.plain
        #expect(!focused())
        key.window = windows.page
        #expect(focused())
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

    @MainActor
    final class Rig {
        let clock = ManualClock()
        let timer = Timer()
        let pending = Pending()
        let dispatches = Dispatches()
        let boardDispatches = Dispatches()
        let budget = MainFrameBudget()
        var focused = false
        var passes = 0
        private(set) var pump: CEFMessagePump!

        init() {
            let clock = clock
            let board = CEFPumpBoard(budget: budget, dispatches: boardDispatches, pageHasFocus: { [unowned self] in self.focused })
            pump = CEFMessagePump(work: { [unowned self] in self.passes += 1 }, timer: timer, clock: { clock.seconds },
                                  ledger: WakeupLedger(), board: board)
            pump.setInputPolicy(CEFPumpInputPolicy(pending: pending, dispatches: dispatches,
                                                   refreshInterval: { CEFPumpInputYieldTests.refresh }))
            pump.start()
            timer.fire()
        }
    }
}
