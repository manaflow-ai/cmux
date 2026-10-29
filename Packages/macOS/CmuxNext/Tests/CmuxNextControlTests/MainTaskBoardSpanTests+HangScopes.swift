@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextWakeups
import CoreFoundation
import Darwin
import Foundation
import Testing

// Hang scopes per class: Chrome's per-scope hang deadlines
// (base/threading/hang_watcher.h, `WatchHangsInScope`) on every scheduled main-thread task. A task
// past its class's deadline is recorded once with its owner, class, location and stack, without
// crashing; a nested run loop (menu tracking, a modal panel, a drag) invalidates the scopes, as
// `HangWatcher::InvalidateActiveExpectations` does; work no scheduled task covers is `unattributed`.
extension MainTaskBoardSpanTests {
    /// A 300 ms visible task, end to end on the real watchdog thread in a launch without the task
    /// diagnostics mode (no task-start wake): one task hang record, with its owner, class, posting
    /// location and a stack that names the spinning frame.
    @MainActor
    @Test func aSlowVisibleTaskGetsOneHangRecordWithOwnerClassAndLocation() throws {
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false))
        let budget = MainFrameBudget()
        watchdog.start()
        defer { watchdog.stop() }
        watchdog.attach(board: budget.board, recordTaskBudgets: false)
        let owner = budget.board.owner("SidebarRows")
        let line: UInt = #line + 4
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            // main-proof: performed on the main run loop.
            MainActor.assumeIsolated {
                budget.run(.visible, owner: owner, posted: MainTaskPost(node: .visible)) { spinForTestAction(milliseconds: 300) }
            }
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        CFRunLoopRunInMode(.defaultMode, 30, false)
        let records = watchdog.taskHangs.records()
        #expect(records.count == 1, "one report per task: \(records.map(\.details))")
        let record = try #require(records.first)
        #expect(record.kind == .taskHang)
        #expect(record.details["task_owner"] == .string("SidebarRows"))
        #expect(record.details["task_class"] == .string("visible"))
        let location = record.details["task_location"]?.stringValue ?? ""
        #expect(location.hasSuffix("MainTaskBoardSpanTests+HangScopes.swift:\(line)"), "location: \(location)")
        #expect(record.details["turn_ms"] != nil)
        #expect(record.duration >= .milliseconds(17), "sampled past the 16.7 ms visible deadline")
        #expect(record.frames.contains { $0.symbol?.contains("spinForTestAction") == true },
                "frames: \(record.frames.prefix(8).map(\.description))")
    }

    /// The same 300 ms visible task inside menu tracking (a nested run loop the input dispatch ran):
    /// no hang record, and the dispatch that ran the menu is not one either once the menu returns.
    @MainActor
    @Test func aSlowTaskInsideMenuTrackingGetsNoHangRecord() {
        let clock = HangScopeClock()
        let (budget, watchdog) = Self.hangScopeRig(clock)
        var reported: UInt64 = 0
        var insideScope = MainTaskBoard.HangScope.noTask
        budget.run(.input, owner: budget.board.owner("sendEvent")) {
            clock.now += 1_000_000
            budget.turns.loopEntered() // the menu's tracking loop starts: a nested level
            budget.run(.visible, owner: budget.board.owner("SidebarRows")) {
                clock.now += 300_000_000
                insideScope = budget.board.hangScope
                #expect(watchdog.checkHangScope(now: clock.now, reported: &reported) == nil)
            }
            budget.turns.loopExited() // the menu returns
            clock.now += 200_000_000
            #expect(!budget.board.hangScope.isValid, "the task that ran the menu started before it: invalidated")
            #expect(watchdog.checkHangScope(now: clock.now, reported: &reported) == nil)
        }
        #expect(insideScope.packed != 0 && !insideScope.isValid, "a task inside the nested loop has no valid scope")
        #expect(watchdog.taskHangs.records().isEmpty)
    }

    /// Each class has its deadline: input 100 ms, frame and userBlocking 50 ms, visible, automation and
    /// background 16.7 ms, idle its idle deadline plus 16.7 ms. Below it the watchdog waits for the deadline; at it, one record.
    @MainActor
    @Test func eachClassHasItsOwnHangDeadline() throws {
        #expect(MainTaskBoard.hangScopeNanos(.input) == 100_000_000)
        #expect(MainTaskBoard.hangScopeNanos(.frame) == 50_000_000)
        #expect(MainTaskBoard.hangScopeNanos(.userBlocking) == 50_000_000)
        for workClass: MainWorkClass in [.visible, .automation, .background, .idle] {
            #expect(MainTaskBoard.hangScopeNanos(workClass) == 16_666_667, "\(workClass)")
        }
        #expect(MainTaskBoard.hangScopeEnd(.idle, startNanos: 1_000, idleDeadlineNanos: 40_000_000) == 40_000_000 + 16_666_667)
        #expect(MainTaskBoard.hangScopeEnd(.idle, startNanos: 1_000) == 1_000 + 16_666_667, "a timed-out idle task: from its start")
        let clock = HangScopeClock()
        let (budget, watchdog) = Self.hangScopeRig(clock)
        var reported: UInt64 = 0
        budget.run(.input, owner: budget.board.owner("terminal.key")) {
            let start = clock.now
            clock.now += 99_000_000
            #expect(watchdog.checkHangScope(now: clock.now, reported: &reported) == start + 100_000_000, "waits for the deadline")
            clock.now += 1_000_000
            #expect(watchdog.checkHangScope(now: clock.now, reported: &reported) == nil)
            clock.now += 500_000_000
            _ = watchdog.checkHangScope(now: clock.now, reported: &reported)
        }
        let records = watchdog.taskHangs.records()
        #expect(records.count == 1, "reported once however long it runs")
        let record = try #require(records.first)
        #expect(record.details["task_owner"] == .string("terminal.key"))
        #expect(record.details["task_class"] == .string("input"))
        #expect(record.details["hang_deadline_ms"] == .number(100))
        #expect(record.details["task_location"] == nil, "an unposted task names no location")
    }

    /// A nested task's time is not its outer task's: a control batch that runs a 60 ms request is not
    /// past its own 16.7 ms deadline when the request returns, so only the request is reported.
    @MainActor
    @Test func aNestedTaskHangIsNotItsOuterTasksToo() {
        let clock = HangScopeClock()
        let (budget, watchdog) = Self.hangScopeRig(clock)
        var reported: UInt64 = 0
        budget.run(.automation, owner: budget.board.owner("Control.frames")) {
            budget.run(.automation, owner: budget.board.owner("tab.focus")) {
                clock.now += 60_000_000
                _ = watchdog.checkHangScope(now: clock.now, reported: &reported)
            }
            clock.now += 1_000_000
            #expect(watchdog.checkHangScope(now: clock.now, reported: &reported) != nil, "the batch's own 1 ms is under its deadline")
        }
        #expect(watchdog.taskHangs.records().map { $0.details["task_owner"] } == [.string("tab.focus")])
    }

    /// An action span inside a scheduled task (an action a control request runs) is not that task's time
    /// either: after a 60 ms span, and after a nested task the budget publishes the batch again for, the
    /// batch is judged on its own time and reported only once that passes its 16.7 ms deadline.
    @MainActor
    @Test func anActionSpanInsideATaskIsNotItsTasksHang() {
        let clock = HangScopeClock()
        let (budget, watchdog) = Self.hangScopeRig(clock)
        let board = budget.board
        var reported: UInt64 = 0
        budget.run(.automation, owner: board.owner("Control.frames")) {
            let token = board.beginSpan(.input, owner: board.internOwner("tab.close"), budgetNanos: 10_000_000, startNanos: clock.now)
            clock.now += 60_000_000
            board.endSpan(token, nowNanos: clock.now)
            clock.now += 1_000_000
            #expect(watchdog.checkHangScope(now: clock.now, reported: &reported) != nil, "after the span: the batch's own 1 ms")
            budget.run(.automation, owner: board.owner("tab.focus")) { clock.now += 1_000_000 }
            clock.now += 1_000_000
            #expect(watchdog.checkHangScope(now: clock.now, reported: &reported) != nil, "after a nested task: the batch's own 2 ms")
            clock.now += 20_000_000
            #expect(watchdog.checkHangScope(now: clock.now, reported: &reported) == nil)
        }
        #expect(watchdog.taskHangs.records().map { $0.details["task_owner"] } == [.string("Control.frames")])
    }

    /// A hang no scheduled task covers (AppKit's own work, an unclassified job) is `unattributed`, with
    /// the turn so far; a hang inside a task names it.
    @MainActor
    @Test func aHangInAnUnclassifiedJobIsUnattributed() {
        let clock = HangScopeClock()
        let (budget, watchdog) = Self.hangScopeRig(clock)
        let none = watchdog.hangAttribution(budget.board.hangScope, stillBlocked: true, now: clock.now)
        #expect(none.task == nil)
        #expect(none.owner == "unattributed" && none.taskClass == "unattributed" && none.location == nil)
        #expect(none.details["task_owner"] == .string("unattributed"))
        #expect(none.details["turn_ms"] != nil)
        budget.run(.background, owner: budget.board.owner("Snapshot.record"), posted: MainTaskPost(enqueueNanos: clock.now)) {
            let named = watchdog.hangAttribution(budget.board.hangScope, stillBlocked: true, now: clock.now)
            #expect(named.owner == "Snapshot.record" && named.taskClass == "background")
            #expect(named.location?.hasPrefix("CmuxNextControlTests/") == true, "\(named.location ?? "nil")")
            let ended = watchdog.hangAttribution(budget.board.hangScope, stillBlocked: false, now: clock.now)
            #expect(ended.owner == "unattributed", "the stall ended before the sample: the task is not named")
        }
    }

    /// The hang scope adds no allocation to a task: a thousand scheduled tasks, each publishing its
    /// scope, and their scope reads, allocate nothing on the main thread.
    @MainActor
    @Test func aTaskWithItsHangScopeAllocatesNothing() throws {
        let budget = MainFrameBudget(board: MainTaskBoard(ledger: MainOwnerLedger(capacity: 256, folding: .manual)))
        let owner = budget.board.owner("bench")
        let control = HangScopeMallocProbe.allocations { _ = ContiguousArray(repeating: 1, count: 64).count }
        try #require((control ?? 0) > 0, "malloc_logger saw no allocation on this thread: the probe cannot measure here")
        for _ in 0..<16 { budget.run(.frame, owner: owner) { _ = budget.board.hangScope } }
        var valid = 0
        let measured = try #require(HangScopeMallocProbe.allocations {
            for _ in 0..<1_000 {
                budget.run(.frame, owner: owner) { if budget.board.hangScope.isValid { valid += 1 } }
            }
        })
        #expect(measured == 0)
        #expect(valid == 1_000)
    }

    /// A budget and a watchdog on one hand-moved clock, with no stack sampler (these tests check the
    /// scope on the main thread itself, which a sampler would suspend).
    @MainActor
    private static func hangScopeRig(_ clock: HangScopeClock) -> (MainFrameBudget, MainThreadWatchdog) {
        let budget = MainFrameBudget(uptimeNanos: { [clock] in clock.now })
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false),
                                          uptime: { 0 })
        watchdog.attach(board: budget.board, recordTaskBudgets: false)
        return (budget, watchdog)
    }
}

/// A clock the hang scope tests move by hand.
private final class HangScopeClock {
    var now: UInt64 = 1_000_000_000
}

/// Counts the allocations one thread makes, through libmalloc's `malloc_logger` hook (as
/// MainTurnMeterTests' probe does).
private enum HangScopeMallocProbe {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// `MALLOC_LOG_TYPE_ALLOCATE` (libmalloc stack_logging.h).
    static let allocateType: UInt32 = 2
    static let count = Atomic<Int>(0)
    static let thread = Atomic<UInt64>(0)

    /// The allocations `body` makes on this thread, or nil when the hook is missing.
    static func allocations(_ body: () -> Void) -> Int? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let slot = symbol.assumingMemoryBound(to: Logger?.self)
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        count.store(0, ordering: .relaxed)
        thread.store(id, ordering: .relaxed)
        let previous = slot.pointee
        slot.pointee = { type, _, _, _, _, _ in
            guard type & HangScopeMallocProbe.allocateType != 0 else { return }
            var id: UInt64 = 0
            pthread_threadid_np(nil, &id)
            if id == HangScopeMallocProbe.thread.load(ordering: .relaxed) { _ = HangScopeMallocProbe.count.wrappingAdd(1, ordering: .relaxed) }
        }
        body()
        slot.pointee = previous
        thread.store(0, ordering: .relaxed)
        return count.load(ordering: .relaxed)
    }
}
