@testable import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups
import CoreFoundation
import Darwin
import Foundation
import Testing

/// A person's action as a span on the main-thread board (PL-instant's per-action budget monitor):
/// lock-free to mark, and the watchdog samples an action that runs past its budget and records it
/// with the action's id and a stack.
@Suite(.serialized, .timeLimit(.minutes(1))) struct MainTaskBoardSpanTests {
    @MainActor
    @Test func aSlowActionSpanGetsAnOverBudgetRecordWithItsOwnerAndAStack() throws {
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false))
        let board = MainTaskBoard()
        watchdog.start()
        defer { watchdog.stop() }
        watchdog.attach(board: board, recordTaskBudgets: true)
        let owner = board.internOwner("newWindow")
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            let token = board.beginSpan(.input, owner: owner, budgetNanos: 10_000_000, startNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            spinForTestAction(milliseconds: 40)
            board.endSpan(token, nowNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        CFRunLoopRunInMode(.defaultMode, 30, false)
        let record = try #require(watchdog.overBudget.records().first, "no over-budget record for a 40 ms action with a 10 ms budget")
        #expect(record.kind == .overBudget)
        #expect(record.details["task_owner"] == .string("newWindow"))
        #expect(record.details["task_class"] == .string("input"))
        #expect(record.duration >= .milliseconds(40))
        #expect(!record.addresses.isEmpty, "the stack sampled when the action crossed its budget")
        #expect(record.frames.contains { $0.symbol?.contains("spinForTestAction") == true },
                "frames: \(record.frames.prefix(8).map(\.description))")
        #expect(board.running == nil, "the span put back what it covered (nothing)")
    }

    @MainActor
    @Test func aSpanInsideAScheduledTaskPutsTheTaskBack() {
        let budget = MainFrameBudget()
        let owner = budget.board.internOwner("tab.focus")
        var during: MainTaskBoard.Task?
        var after: MainTaskBoard.Task?
        budget.run(.automation, owner: budget.board.owner("Control.frames")) {
            let token = budget.board.beginSpan(.input, owner: owner, budgetNanos: 10_000_000, startNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            during = budget.board.running
            budget.board.endSpan(token, nowNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            after = budget.board.running
        }
        #expect(during?.owner == "tab.focus")
        #expect(after?.owner == "Control.frames")
    }

    /// Marking an action costs a few atomic stores: printed in ns per begin/end pair, bounded far
    /// above what atomics cost so a loaded runner never fails it, far below what a lock or an
    /// allocation per action would make it.
    @MainActor
    @Test func beginAndEndOfASpanCostNanoseconds() {
        let board = MainTaskBoard()
        let owner = board.internOwner("terminal.key")
        let count = 200_000
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for _ in 0..<count {
            let token = board.beginSpan(.input, owner: owner, budgetNanos: 10_000_000, startNanos: start)
            board.endSpan(token, nowNanos: start)
        }
        let perPair = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / Double(count)
        print("MainTaskBoard span begin+end: \(String(format: "%.1f", perPair)) ns")
        #expect(perPair < 2_000)
    }

    // MARK: Per-owner ledger

    /// Known waits and run times land in their buckets: 98 tasks that waited 1 ms and 2 that waited
    /// 40 ms give p50 and p95 in the 1 ms bucket, p99 and max at 40 ms; run time likewise.
    @MainActor
    @Test func knownWaitsLandInTheirBuckets() throws {
        let (budget, clock) = Self.ledgerBudget()
        let owner = budget.board.owner("SidebarRows")
        for index in 0..<100 {
            let wait: UInt64 = index < 98 ? 1_000_000 : 40_000_000
            let post = MainTaskPost(enqueueNanos: clock.now, node: .visible)
            clock.now += wait
            budget.run(.visible, owner: owner, posted: post) { clock.now += index < 98 ? 200_000 : 3_000_000 }
        }
        let row = try #require(budget.board.ownerSnapshot().owners.first { $0.owner == "SidebarRows" })
        #expect(row.workClass == .visible)
        #expect(row.tasks == 100)
        #expect(row.wait.count == 100)
        #expect((1_000_000...1_250_000).contains(row.wait.p50Nanos), "p50 \(row.wait.p50Nanos)")
        #expect((1_000_000...1_250_000).contains(row.wait.p95Nanos), "p95 \(row.wait.p95Nanos)")
        #expect(row.wait.p99Nanos == 40_000_000, "p99 is the 40 ms bucket, capped at the exact max")
        #expect(row.wait.maxNanos == 40_000_000)
        #expect((200_000...250_000).contains(row.run.p50Nanos), "run p50 \(row.run.p50Nanos)")
        #expect(row.run.p99Nanos == 3_000_000)
        #expect(row.runTotalNanos == 98 * 200_000 + 2 * 3_000_000)
    }

    /// Each owner and class is its own row, with its node states and its posting locations; a task
    /// run without a post counts its run time under node state `none`, with no wait.
    @MainActor
    @Test func nodeStateAndPostedFromAreReportedPerOwner() throws {
        let (budget, clock) = Self.ledgerBudget()
        let rows = budget.board.owner("SidebarRows")
        let control = budget.board.owner("Control.frames")
        let hiddenLine: UInt = #line + 1
        let hidden = MainTaskPost(enqueueNanos: clock.now, node: .hidden)
        let visibleLine: UInt = #line + 1
        let visible = MainTaskPost(enqueueNanos: clock.now, node: .visible)
        budget.run(.background, owner: rows, posted: hidden) { clock.now += 10_000 }
        budget.run(.visible, owner: rows, posted: visible) { clock.now += 10_000 }
        budget.run(.visible, owner: rows, posted: visible) { clock.now += 10_000 }
        budget.run(.automation, owner: control) { clock.now += 10_000 }
        let owners = budget.board.ownerSnapshot().owners
        let background = try #require(owners.first { $0.owner == "SidebarRows" && $0.workClass == .background })
        #expect(background.nodes == [.hidden: 1])
        let hiddenSite = background.sites.first?.location ?? ""
        #expect(hiddenSite.hasSuffix("MainTaskBoardSpanTests.swift:\(hiddenLine)"), "\(background.sites)")
        let shown = try #require(owners.first { $0.owner == "SidebarRows" && $0.workClass == .visible })
        #expect(shown.nodes == [.visible: 2])
        #expect(shown.sites.count == 1)
        #expect(shown.sites.first?.tasks == 2)
        let shownSite = shown.sites.first?.location ?? ""
        #expect(shownSite.hasSuffix("MainTaskBoardSpanTests.swift:\(visibleLine)"), "\(shown.sites)")
        let unposted = try #require(owners.first { $0.owner == "Control.frames" })
        #expect(unposted.nodes == [.none: 1])
        #expect(unposted.wait.count == 0, "a task without a post has no wait")
        #expect(unposted.run.count == 1)
        #expect(unposted.sites.isEmpty)
    }

    /// A posted task inside a posted task keeps its own post: the inner one's wait is its own, and
    /// the outer one's run time leaves out the inner one's. An unposted task in between takes no post.
    @MainActor
    @Test func nestedPostedTasksKeepTheirOwnPosts() throws {
        let (budget, clock) = Self.ledgerBudget()
        let outer = budget.board.owner("Control.frames")
        let inner = budget.board.owner("tab.focus")
        let plain = budget.board.owner("plain")
        let outerPost = MainTaskPost(enqueueNanos: clock.now, node: .visible)
        clock.now += 5_000_000
        budget.run(.automation, owner: outer, posted: outerPost) {
            clock.now += 1_000_000
            budget.run(.visible, owner: plain) {
                let innerPost = MainTaskPost(enqueueNanos: clock.now, node: .occluded)
                clock.now += 2_000_000
                budget.run(.visible, owner: inner, posted: innerPost) { clock.now += 3_000_000 }
            }
            clock.now += 1_000_000
        }
        let owners = budget.board.ownerSnapshot().owners
        let outerRow = try #require(owners.first { $0.owner == "Control.frames" })
        let innerRow = try #require(owners.first { $0.owner == "tab.focus" })
        let plainRow = try #require(owners.first { $0.owner == "plain" })
        #expect(outerRow.wait.maxNanos == 5_000_000)
        #expect(outerRow.run.maxNanos == 2_000_000, "the outer task's own time: 1 + 1 ms")
        #expect(outerRow.nodes == [.visible: 1])
        #expect(innerRow.wait.maxNanos == 2_000_000)
        #expect(innerRow.run.maxNanos == 3_000_000)
        #expect(innerRow.nodes == [.occluded: 1])
        #expect(plainRow.nodes == [.none: 1])
        #expect(plainRow.run.maxNanos == 2_000_000, "the plain task's own time: the 2 ms before the inner task")
    }

    /// A full ring counts the record as dropped and returns: 10 tasks into 4 slots with no fold keep
    /// 4 and drop 6, and the tasks themselves all run.
    @MainActor
    @Test func aFullRingCountsDroppedAndNeverBlocks() {
        let (budget, clock) = Self.ledgerBudget(capacity: 4)
        let owner = budget.board.owner("storm")
        var ran = 0
        for _ in 0..<10 {
            budget.run(.automation, owner: owner, posted: MainTaskPost(enqueueNanos: clock.now)) { ran += 1 }
        }
        #expect(ran == 10)
        let snapshot = budget.board.ownerSnapshot()
        #expect(snapshot.dropped == 6)
        #expect(snapshot.recorded == 4)
        #expect(snapshot.pending == 0)
        #expect(snapshot.owners.first?.tasks == 4)
        // After the fold the ring takes records again.
        budget.run(.automation, owner: owner, posted: MainTaskPost(enqueueNanos: clock.now)) { ran += 1 }
        #expect(budget.board.ownerSnapshot().recorded == 5)
    }

    /// `debug.main_budget` lists the owners with p50/p95/p99/max and node states, and the ledger's
    /// counts, next to the class counters; a reset clears both.
    @MainActor
    @Test func theReportListsOwnersAndResetClearsThem() async throws {
        let (budget, clock) = Self.ledgerBudget()
        let owner = budget.board.owner("ContentPresentation")
        let post = MainTaskPost(enqueueNanos: clock.now, node: .hidden)
        clock.now += 2_000_000
        budget.run(.visible, owner: owner, posted: post) { clock.now += 1_000_000 }
        let report = await budget.board.mainBudgetReport(budget, reset: true)
        let rows = try #require(report["owners"]?.arrayValue)
        let row = try #require(rows.first { $0["owner"]?.stringValue == "ContentPresentation" })
        #expect(row["class"]?.stringValue == "visible")
        #expect(row["tasks"]?.intValue == 1)
        #expect(row["wait"]?["max_ms"]?.doubleValue == 2)
        #expect(row["wait"]?["p99_ms"]?.doubleValue == 2)
        #expect(row["run"]?["p50_ms"]?.doubleValue == 1)
        #expect(row["nodes"]?["hidden"]?.intValue == 1)
        let location = row["posted_from"]?.arrayValue?.first?["location"]?.stringValue ?? ""
        #expect(location.contains("MainTaskBoardSpanTests.swift:"), "\(location)")
        #expect(report["owner_ledger"]?["dropped"]?.intValue == 0)
        #expect(report["owner_ledger"]?["recorded"]?.intValue == 1)
        #expect(report["classes"]?["visible"]?["tasks"]?.intValue == 1, "the existing fields stay")
        let cleared = await budget.board.mainBudgetReport(budget, reset: false)
        #expect(cleared["owners"]?.arrayValue?.isEmpty == true)
        #expect(cleared["owner_ledger"]?["recorded"]?.intValue == 0)
        #expect(cleared["classes"]?["visible"]?["tasks"]?.intValue == 0)
    }

    /// A scheduler post records its wait from the post to its start: posted at t, run on the frame
    /// 17 ms later, it waited 17 ms, as the posting site's owner, with no node.
    @MainActor
    @Test func aSchedulerPostRecordsItsWaitFromThePost() throws {
        let rig = LedgerRig()
        defer { rig.stop() }
        var ran = false
        let line: UInt = #line + 1
        rig.work.post(.visible, owner: "SidebarRows") { ran = true }
        rig.frames(1)
        #expect(ran)
        let row = try #require(rig.work.board.ownerSnapshot().owners.first { $0.owner == "SidebarRows" })
        #expect(row.workClass == .visible)
        #expect(row.wait.count == 1)
        #expect(row.wait.maxNanos == 17_000_000)
        #expect(row.nodes == [.none: 1])
        #expect(row.sites.first?.location.hasSuffix("MainTaskBoardSpanTests.swift:\(line)") == true, "\(row.sites)")
    }

    /// A node queue's task is recorded with its node's state when it runs and its wait from its
    /// first post: a keyed post held while the tab is hidden runs on show as `visible`, having
    /// waited through the hidden frames, at the latest post's site; a background task run at a
    /// hidden wake is `hidden`.
    @MainActor
    @Test func aNodeQueueTaskRecordsItsNodeStateAndItsWaitFromTheFirstPost() throws {
        let rig = LedgerRig()
        defer { rig.stop() }
        var wakes: [@MainActor () -> Void] = []
        rig.work.hiddenWake = { _, wake in wakes.append(wake) }
        let window = VisibilityNode(root: "window", own: .visible)
        let tab = VisibilityNode("tab", own: .hidden, parent: window)
        let titles = tab.queue(.visible, owner: "Tab.title", on: rig.work)
        let persist = tab.queue(.background, owner: "Tab.persist", on: rig.work)
        titles.post(key: "title") {}
        rig.advance(1_000_000)
        let line: UInt = #line + 1
        titles.post(key: "title") {}
        persist.post {}
        rig.frames(2)
        for wake in wakes { wake() }
        rig.frames(1)
        tab.set(.visible)
        rig.frames(1)
        let owners = rig.work.board.ownerSnapshot().owners
        let title = try #require(owners.first { $0.owner == "Tab.title" })
        #expect(title.nodes == [.visible: 1])
        #expect(title.wait.maxNanos == 1_000_000 + 4 * 17_000_000, "from the first post through three hidden frames and the shown one")
        #expect(title.sites.first?.location.hasSuffix("MainTaskBoardSpanTests.swift:\(line)") == true, "\(title.sites)")
        let background = try #require(owners.first { $0.owner == "Tab.persist" })
        #expect(background.nodes == [.hidden: 1])
        #expect(background.wait.maxNanos == 3 * 17_000_000)
    }

    /// A posted task's whole run (board, budget and its ledger slot), in ns per task: every timed
    /// task writes its slot (the ring is folded between rounds, untimed), none takes the drop path.
    /// The slot write alone, against its 0.1 us budget, is `MainOwnerLedgerTests/aLedgerWriteCostsUnderItsBudget`.
    @MainActor
    @Test func aPostedTaskWithItsLedgerSlotCostsNanoseconds() {
        let ledger = MainOwnerLedger(capacity: 256, folding: .manual)
        let budget = MainFrameBudget(board: MainTaskBoard(ledger: ledger))
        let owner = budget.board.owner("bench")
        let rounds = 400
        var timed: UInt64 = 0
        for _ in 0..<rounds {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            for _ in 0..<ledger.capacity {
                budget.run(.frame, owner: owner, posted: MainTaskPost(enqueueNanos: start)) {}
            }
            timed &+= clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start
            ledger.fold()
        }
        let count = rounds * ledger.capacity
        let perTask = Double(timed) / Double(count)
        print("MainFrameBudget posted run with ledger slot: \(String(format: "%.1f", perTask)) ns")
        #expect(perTask < 5_000)
        let snapshot = budget.board.ownerSnapshot()
        #expect(snapshot.dropped == 0, "every timed task wrote its slot")
        #expect(snapshot.recorded == UInt64(count))
    }

    /// A pump that finds its node hidden runs nothing and stays out of the ledger: posted while the
    /// tab is visible, hidden before the frame, shown again, the task is recorded once, as visible,
    /// with one wait from its post.
    @MainActor
    @Test func aPumpThatRunsNothingIsNotRecorded() throws {
        let rig = LedgerRig()
        defer { rig.stop() }
        let window = VisibilityNode(root: "window", own: .visible)
        let tab = VisibilityNode("tab", own: .visible, parent: window)
        let titles = tab.queue(.visible, owner: "Tab.title", on: rig.work)
        var ran = 0
        titles.post(key: "title") { ran += 1 }
        tab.set(.hidden)
        rig.frames(1)
        #expect(ran == 0, "the hidden tab's task ran")
        tab.set(.visible)
        rig.frames(1)
        #expect(ran == 1)
        let row = try #require(rig.work.board.ownerSnapshot().owners.first { $0.owner == "Tab.title" })
        #expect(row.tasks == 1, "the pump that ran nothing was recorded")
        #expect(row.wait.count == 1)
        #expect(row.wait.maxNanos == 2 * 17_000_000, "from the post through the hidden frame and the shown one")
        #expect(row.nodes == [.visible: 1])
    }

    /// A pump whose queue a voter disabled runs nothing either: recorded once, when it runs.
    @MainActor
    @Test func aPumpOfADisabledQueueIsNotRecorded() throws {
        let rig = LedgerRig()
        defer { rig.stop() }
        let window = VisibilityNode(root: "window", own: .visible)
        let titles = window.queue(.automation, owner: "Window.title", on: rig.work)
        let voter = titles.makeVoter()
        titles.post {}
        titles.setEnabled(false, by: voter)
        rig.frames(1)
        titles.setEnabled(true, by: voter)
        rig.frames(1)
        let row = try #require(rig.work.board.ownerSnapshot().owners.first { $0.owner == "Window.title" })
        #expect(row.tasks == 1)
        #expect(row.wait.count == 1)
        #expect(row.nodes == [.visible: 1])
    }

    @MainActor
    private static func ledgerBudget(capacity: Int = 1024) -> (MainFrameBudget, LedgerClock) {
        let clock = LedgerClock()
        let board = MainTaskBoard(ledger: MainOwnerLedger(capacity: capacity, folding: .manual))
        return (MainFrameBudget(board: board, uptimeNanos: { [clock] in clock.now }), clock)
    }
}

/// A clock the ledger tests move by hand: the budget and the posts read the same one.
private final class LedgerClock {
    var now: UInt64 = 1_000_000_000
}

/// A scheduler on a fake link and a hand-moved clock, with a manual-fold ledger; a keeper client
/// keeps the link running, so posts tick on ``frames(_:)``.
@MainActor
private final class LedgerRig {
    let work: MainWorkScheduler
    private let clock: LedgerClock
    private var timestamp: Double = 1
    private let keeper: FrameClient

    init() {
        let clock = LedgerClock()
        self.clock = clock
        let board = MainTaskBoard(ledger: MainOwnerLedger(capacity: 64, folding: .manual))
        work = MainWorkScheduler.testing(budget: MainFrameBudget(board: board, uptimeNanos: { [clock] in clock.now })) { _ in LedgerFakeLink() }
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
    }

    /// Moves the clock by `nanos` without a frame.
    func advance(_ nanos: UInt64) { clock.now += nanos }

    /// Fires `count` frames, 17 ms apart.
    func frames(_ count: Int) {
        for _ in 0..<count {
            clock.now += 17_000_000
            timestamp += 1.0 / 60
            work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
        }
    }

    func stop() { keeper.deactivate() }
}

@MainActor
private final class LedgerFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

/// Busy-waits on the main thread so the watchdog's stack names this frame.
@inline(never)
func spinForTestAction(milliseconds: Int) {
    let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + UInt64(milliseconds) * 1_000_000
    while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < end {}
}
