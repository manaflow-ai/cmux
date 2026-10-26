import CmuxNextCompat
import CmuxNextHibernation
@testable import CmuxNextPages
@testable import CmuxNextWakeups
import Foundation
import Testing

/// ``PageLifecycle`` takes show and hide from its caller (the content lifecycle), runs the planner
/// only at its one one-shot deadline, thaws a page before its show returns, and does O(changed pages)
/// work per event (p13-webui-022). The deadline is a real ``MainDeadline`` on a wake-up queue whose
/// timer and uptime only the test moves: a pass runs only when that wake fires.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct PageLifecycleTests {
    /// A page that logs each step and counts reads of its keep reasons.
    private final class FakePage {
        let name: String
        let log: Log
        var reasons: Set<PageLifecyclePlanner.KeepReason> = []
        var reasonReads = 0
        weak var lifecycle: PageLifecycle?

        init(_ name: String, log: Log) {
            self.name = name
            self.log = log
        }
    }

    private final class Log {
        var lines: [String] = []
        var passes = 0
    }

    private struct Target: PageLifecycleTarget {
        let page: FakePage
        var object: AnyObject? { page }
        var lifecycleGroup: String? { "privileged" }
        var lifecycleKeepReasons: Set<PageLifecyclePlanner.KeepReason> {
            page.reasonReads += 1
            return page.reasons
        }

        func reportsReasonChanges(to lifecycle: PageLifecycle) { page.lifecycle = lifecycle }
        func freeze() { page.log.lines.append("freeze \(page.name)") }
        func thaw() { page.log.lines.append("thaw \(page.name)") }
        func discard() { page.log.lines.append("discard \(page.name)") }
    }

    private let log = Log()
    private let rig = LifecycleDeadlineRig()
    private let lifecycle: PageLifecycle

    init() {
        lifecycle = PageLifecycle(deadlines: rig.scheduler)
        let log = log
        lifecycle.didRunPass = { log.passes += 1 }
    }

    private func page(_ name: String) -> FakePage { FakePage(name, log: log) }

    /// The one armed wake fires, as the run loop's timer would, then the frame the pass is posted in:
    /// one pass runs, at its due time. Nothing else runs a pass in these tests.
    private func fireDuePass(sourceLocation: SourceLocation = #_sourceLocation) throws {
        let due = try #require(lifecycle.nextPassAt, sourceLocation: sourceLocation)
        #expect(rig.queue.count == 1, "one wake pending, not a timer per page", sourceLocation: sourceLocation)
        let passes = log.passes
        rig.fire()
        #expect(log.passes == passes + 1, "the wake ran no pass", sourceLocation: sourceLocation)
        #expect(rig.now >= due, sourceLocation: sourceLocation)
    }

    private func near(_ value: Duration?, _ expected: Duration) -> Bool {
        guard let value else { return false }
        return abs((value - expected) / .milliseconds(1)) < 20
    }

    @Test func hideArmsOneDeadlineAtTheEndOfRecentlyVisibleAndNoPassRunsBefore() throws {
        let settings = page("settings")
        lifecycle.show("a", page: Target(page: settings))
        #expect(lifecycle.nextPassAt == nil)
        #expect(rig.queue.count == 0)
        rig.advance(to: .seconds(3))
        lifecycle.hide("a", page: Target(page: settings))
        #expect(lifecycle.nextPassAt == .seconds(13))
        #expect(rig.queue.count == 1)
        // The wake is not due yet: firing the queue early runs nothing.
        rig.fire(movingTime: false)
        #expect(log.passes == 0)
        #expect(settings.reasonReads == 0) // a hide plans nothing
        #expect(lifecycle.state(of: "a") == .hidden)
    }

    @Test func theOnlyHiddenPageIsMostRecentlyUsedSoItIsNotFrozenThenDiscardedOnItsDeadline() throws {
        let settings = page("settings")
        lifecycle.show("a", page: Target(page: settings))
        lifecycle.hide("a", page: Target(page: settings))
        try fireDuePass()
        #expect(lifecycle.state(of: "a") == .hidden)
        #expect(log.lines.isEmpty)
        // One deadline at a time: the discard at 300 s, not a repeating tick.
        #expect(near(lifecycle.nextPassAt, .seconds(300)))
        #expect(rig.queue.count == 1)
        try fireDuePass()
        #expect(lifecycle.state(of: "a") == .discarded)
        #expect(log.lines == ["discard settings"])
        #expect(lifecycle.nextPassAt == nil)
        #expect(rig.queue.count == 0, "a one-shot deadline: nothing left armed")
    }

    @Test func anOlderHiddenPageFreezesOnceItIsNoLongerRecentlyVisible() throws {
        let history = page("history"), cloud = page("cloud")
        lifecycle.hide("h", page: Target(page: history))
        rig.advance(to: .seconds(5))
        lifecycle.hide("c", page: Target(page: cloud))
        // The earlier page lost mostRecentlyUsed now; it may freeze at 10 s.
        #expect(lifecycle.nextPassAt == .seconds(10))
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .frozen)
        #expect(lifecycle.state(of: "c") == .hidden)
        #expect(log.lines == ["freeze history"])
    }

    @Test func showOfARunningPageDoesNotThaw() {
        let settings = page("settings")
        lifecycle.hide("a", page: Target(page: settings))
        lifecycle.show("a", page: Target(page: settings))
        #expect(log.lines.isEmpty)
        #expect(lifecycle.state(of: "a") == .active)
    }

    @Test func aFrozenPageThawsInsideItsShow() throws {
        let history = page("history"), cloud = page("cloud")
        lifecycle.hide("h", page: Target(page: history))
        rig.advance(to: .seconds(5))
        lifecycle.hide("c", page: Target(page: cloud))
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .frozen)
        lifecycle.show("h", page: Target(page: history))
        #expect(log.lines == ["freeze history", "thaw history"])
        #expect(lifecycle.state(of: "h") == .active)
    }

    @Test func aDiscardedPageThawsWhenShown() throws {
        let settings = page("settings")
        lifecycle.hide("a", page: Target(page: settings))
        try fireDuePass()
        try fireDuePass()
        #expect(lifecycle.state(of: "a") == .discarded)
        lifecycle.show("a", page: Target(page: settings))
        #expect(log.lines == ["discard settings", "thaw settings"])
    }

    @Test func aFreezeBlockingReasonKeepsThePageRunning() throws {
        let history = page("history"), cloud = page("cloud")
        history.reasons = [.audible]
        lifecycle.hide("h", page: Target(page: history))
        rig.advance(to: .seconds(5))
        lifecycle.hide("c", page: Target(page: cloud))
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .hidden)
        #expect(log.lines.isEmpty)
    }

    /// `.loading` is not time-bound: the planner arms nothing for it. The load's end is an event
    /// (``PageLifecycle/pageReasonsDidChange(_:)``) that arms a pass, so a page that hid before its
    /// load ended freezes once it ends, without another show or hide.
    @Test func aPageHiddenWhileLoadingFreezesWhenItsLoadEndsWithNoOtherEvent() throws {
        let history = page("history"), cloud = page("cloud")
        history.reasons = [.loading]
        lifecycle.hide("h", page: Target(page: history))
        #expect(history.lifecycle === lifecycle, "the page reports its reason changes")
        rig.advance(to: .seconds(5))
        lifecycle.hide("c", page: Target(page: cloud))
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .hidden)
        // The only wake left is the other page's discard: nothing would ever look at the loading page again.
        #expect(near(lifecycle.nextPassAt, .seconds(305)))
        rig.advance(to: .seconds(20))
        history.reasons = []
        history.lifecycle?.pageReasonsDidChange(history)
        #expect(lifecycle.nextPassAt == .seconds(20))
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .frozen)
        #expect(log.lines == ["freeze history"])
    }

    @Test func aReasonChangeOfAShownOrUnknownPageArmsNothing() {
        let shown = page("shown"), stranger = page("stranger")
        lifecycle.show("s", page: Target(page: shown))
        lifecycle.pageReasonsDidChange(shown)
        lifecycle.pageReasonsDidChange(stranger)
        #expect(lifecycle.nextPassAt == nil)
        #expect(rig.queue.count == 0)
    }

    @Test func anOwnerReasonThawsAFrozenPageAtOnceAndDroppingItArmsAPass() throws {
        let history = page("history"), cloud = page("cloud")
        lifecycle.hide("h", page: Target(page: history))
        rig.advance(to: .seconds(5))
        lifecycle.hide("c", page: Target(page: cloud))
        try fireDuePass()
        lifecycle.setKeepReasons([.audible], for: "h")
        #expect(lifecycle.state(of: "h") == .hidden)
        #expect(log.lines == ["freeze history", "thaw history"])
        rig.advance(to: .seconds(20))
        lifecycle.setKeepReasons([], for: "h")
        #expect(lifecycle.nextPassAt == .seconds(20))
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .frozen)
    }

    @Test func eventsTouchOnlyTheChangedPageAndAPassReadsOnlyHiddenPages() throws {
        let shown = (0..<100).map { page("p\($0)") }
        for (index, fake) in shown.enumerated() { lifecycle.show("k\(index)", page: Target(page: fake)) }
        let hiding = page("hiding")
        lifecycle.show("h", page: Target(page: hiding))
        lifecycle.hide("h", page: Target(page: hiding))
        #expect(shown.allSatisfy { $0.reasonReads == 0 })
        try fireDuePass()
        #expect(shown.allSatisfy { $0.reasonReads == 0 })
        #expect(hiding.reasonReads == 1)
    }

    @Test func criticalPressureLooksAgainAtOnceAndDiscardsSooner() throws {
        let history = page("history"), cloud = page("cloud")
        lifecycle.hide("h", page: Target(page: history))
        rig.advance(to: .seconds(5))
        lifecycle.hide("c", page: Target(page: cloud))
        try fireDuePass()
        rig.advance(to: .seconds(30))
        lifecycle.setConditions(.init(pressure: .critical))
        #expect(lifecycle.nextPassAt == .seconds(30))
        try fireDuePass()
        // Chrome's urgent pace: one discard per pass, the longest hidden first, the next 5 s later.
        #expect(lifecycle.state(of: "h") == .discarded)
        #expect(lifecycle.state(of: "c") == .hidden)
        #expect(near(lifecycle.nextPassAt, .seconds(35)))
        try fireDuePass()
        #expect(lifecycle.state(of: "c") == .discarded)
        #expect(log.lines == ["freeze history", "discard history", "discard cloud"])
    }

    /// `browser.hibernation` off reaches the planner as ``PageLifecyclePlanner/KeepReason/hibernationOff``:
    /// a hidden page is never discarded, and the setting's change arms a pass.
    @Test func withHibernationOffNoPageIsDiscardedAndTheChangeArmsAPass() throws {
        let settings = page("settings")
        var off = PageLifecyclePlanner.Conditions()
        off.setting.mode = .off
        lifecycle.setConditions(off)
        lifecycle.hide("a", page: Target(page: settings))
        try fireDuePass()
        #expect(lifecycle.nextPassAt == nil, "nothing to look at again while hibernation is off")
        rig.advance(to: .seconds(3_600))
        #expect(lifecycle.state(of: "a") == .hidden)
        lifecycle.setConditions(.init())
        #expect(lifecycle.nextPassAt == .seconds(3_600))
        try fireDuePass()
        #expect(lifecycle.state(of: "a") == .discarded)
    }

    @Test func tabEventsResolveThePageAndIgnoreTabsWithNone() throws {
        let settings = page("settings")
        var lookups: [String] = []
        lifecycle.pageOfTab = { key in
            lookups.append(key)
            return key == "page-tab" ? Target(page: settings) : nil
        }
        lifecycle.tabDidHide("terminal-tab")
        lifecycle.tabDidShow("terminal-tab")
        #expect(lifecycle.pageCount == 0)
        #expect(lifecycle.nextPassAt == nil)
        lifecycle.tabDidHide("page-tab")
        #expect(lifecycle.state(of: "page-tab") == .hidden)
        try fireDuePass()
        try fireDuePass()
        lifecycle.tabDidShow("page-tab")
        #expect(lifecycle.state(of: "page-tab") == .active)
        #expect(log.lines == ["discard settings", "thaw settings"])
        #expect(lookups == ["terminal-tab", "terminal-tab", "page-tab", "page-tab"])
    }

    @Test func removeAndForgetDropThePage() {
        let settings = page("settings"), history = page("history")
        lifecycle.hide("a", page: Target(page: settings))
        lifecycle.hide("b", page: Target(page: history))
        lifecycle.remove("a")
        lifecycle.forget(history)
        #expect(lifecycle.state(of: "a") == nil)
        #expect(lifecycle.state(of: "b") == nil)
        #expect(lifecycle.pageCount == 0)
    }

    @Test func aNewViewForTheSameTabStartsHiddenAndRunning() throws {
        let old = page("old"), new = page("new")
        lifecycle.hide("a", page: Target(page: old))
        try fireDuePass()
        try fireDuePass()
        #expect(lifecycle.state(of: "a") == .discarded)
        // The tab's view was made again (a restore) and hidden before it showed: no thaw of the old one.
        lifecycle.hide("a", page: Target(page: new))
        #expect(lifecycle.state(of: "a") == .hidden)
        #expect(log.lines == ["discard old"])
        lifecycle.forget(old)
        #expect(lifecycle.state(of: "a") == .hidden)
    }

    /// A real page: `.loading` follows its load state (not a first paint, which a hidden page never
    /// makes), its load's end arms a pass, and WebUIHost's close forgets it.
    @Test func aPageWebViewIsLoadingUntilItsLoadEndsAndWebUIHostCloseForgetsIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let host = WebUIHost(chromium: nil, openPanel: nil,
                             memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()),
                             clock: PageTestClock.never)
        host.lifecycle = lifecycle
        let descriptor = PageDescriptor(id: "test.page-lifecycle", resource: "page-lifecycle", processGroup: .viewer, namespaces: [])
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        let target = PageWebViewLifecycle(view)
        #expect(target.lifecycleGroup == "viewer")
        #expect(target.lifecycleKeepReasons.contains(.loading))
        lifecycle.hide("tab", page: target)
        #expect(view.loadState.lifecycle === lifecycle)
        #expect(lifecycle.state(of: "tab") == .hidden)
        rig.advance(to: .seconds(2))
        view.loaded = true // the document finished (either engine's load end), while hidden
        #expect(!target.lifecycleKeepReasons.contains(.loading))
        #expect(lifecycle.nextPassAt == .seconds(2), "the load's end armed no pass")
        view.loaded = false // a new load starts
        #expect(target.lifecycleKeepReasons.contains(.loading))
        view.webView(view.webKitView, didFailProvisionalNavigation: nil, withError: URLError(.cancelled))
        #expect(!target.lifecycleKeepReasons.contains(.loading), "a failed load still counted as loading")
        host.close(view)
        #expect(lifecycle.state(of: "tab") == nil)
    }
}

/// The lifecycle's deadline scheduler on a wake-up queue whose timer never touches the run loop and
/// whose uptime only the test moves, and a main-thread scheduler whose posted work runs only in a
/// hand-fired frame.
@MainActor
private final class LifecycleDeadlineRig {
    let queue: MainWakeUpQueue
    let scheduler: MainDeadlineScheduler
    private let uptime: RigUptime
    private let work: MainWorkScheduler
    private let budgetClock: RigBudgetClock
    private let keeper: FrameClient
    private var frames: Double = 0

    init() {
        let uptime = RigUptime(), budgetClock = RigBudgetClock()
        self.uptime = uptime
        self.budgetClock = budgetClock
        queue = MainWakeUpQueue(energy: EnergyPolicySource(), ledger: WakeupLedger(uptime: { 0 }), uptime: { uptime.now }) { _ in
            RigWakeUpTimer()
        }
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: budgetClock.read),
                                             ledger: WakeupLedger()) { _ in RigFrameLink() }
        self.work = work
        scheduler = MainDeadlineScheduler(work: work, queue: queue)
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
    }

    /// Now on the scheduler's clock.
    var now: Duration { scheduler.uptime }

    /// Moves the uptime forward to `time`.
    func advance(to time: Duration) { uptime.now = max(uptime.now, time.nanosecondCount) }

    /// Runs the queue's wake (with `movingTime`, at its fire date, never earlier than now), then one
    /// frame, in which the actions it posted run.
    func fire(movingTime: Bool = true) {
        if movingTime, let date = scheduler.nextFireNanos { uptime.now = max(uptime.now, date) }
        queue.fire()
        budgetClock.now += 17_000_000
        frames += 1
        work.frameDidFire(timestamp: frames, refreshInterval: 1.0 / 60)
    }
}

/// A timer the queue arms and parks; the rig fires the queue itself.
private final class RigWakeUpTimer: MainWakeUpTimer {
    func arm(at date: UInt64, tolerance: UInt64, now: UInt64) {}
    func park() {}
}

@MainActor
private final class RigFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

/// The rig's uptime in ns: the queue reads it from any thread, only the test's main actor moves it.
private final class RigUptime: Sendable {
    private let value = Atomic<UInt64>(0)

    var now: UInt64 {
        get { value.load(ordering: .relaxed) }
        set { value.store(newValue, ordering: .relaxed) }
    }
}

/// The frame budget's clock (`CLOCK_UPTIME_RAW` ns), one 60 Hz frame further at each fired frame.
@MainActor
private final class RigBudgetClock {
    var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
}
