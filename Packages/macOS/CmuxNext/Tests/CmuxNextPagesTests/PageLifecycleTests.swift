import CmuxNextCompat
import CmuxNextHibernation
@testable import CmuxNextPages
import CmuxNextWakeups
import Foundation
import Testing

/// ``PageLifecycle`` takes show and hide from its caller (the content lifecycle), runs the planner
/// only at its one deadline, thaws a page before its show returns, and does O(changed pages) work
/// per event (p13-webui-022).
@MainActor
struct PageLifecycleTests {
    /// A page that logs each step and counts reads of its keep reasons.
    private final class FakePage {
        let name: String
        let log: Log
        var reasons: Set<PageLifecyclePlanner.KeepReason> = []
        var reasonReads = 0

        init(_ name: String, log: Log) {
            self.name = name
            self.log = log
        }
    }

    private final class Log {
        var lines: [String] = []
    }

    private struct Target: PageLifecycleTarget {
        let page: FakePage
        var object: AnyObject? { page }
        var lifecycleGroup: String? { "privileged" }
        var lifecycleKeepReasons: Set<PageLifecyclePlanner.KeepReason> {
            page.reasonReads += 1
            return page.reasons
        }

        func freeze() { page.log.lines.append("freeze \(page.name)") }
        func thaw() { page.log.lines.append("thaw \(page.name)") }
        func discard() { page.log.lines.append("discard \(page.name)") }
    }

    private final class Uptime {
        var now: Duration = .zero
    }

    private let log = Log()
    private let uptime = Uptime()
    private let lifecycle: PageLifecycle

    init() {
        let uptime = uptime
        // A scheduler nobody runs: no pass fires on its own; each test runs the pass at `nextPassAt`.
        let idle = MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget()))
        lifecycle = PageLifecycle(deadlines: idle, uptime: { uptime.now })
    }

    private func page(_ name: String) -> FakePage { FakePage(name, log: log) }

    /// Runs the armed pass at its deadline, as the DemandTimer would.
    private func runDuePass() throws {
        let due = try #require(lifecycle.nextPassAt)
        uptime.now = max(uptime.now, due)
        lifecycle.runPass()
    }

    @Test func hideArmsOneDeadlineAtTheEndOfRecentlyVisibleAndNoPassRunsBefore() throws {
        var passes = 0
        lifecycle.didRunPass = { passes += 1 }
        let settings = page("settings")
        lifecycle.show("a", page: Target(page: settings))
        #expect(lifecycle.nextPassAt == nil)
        uptime.now = .seconds(3)
        lifecycle.hide("a", page: Target(page: settings))
        #expect(lifecycle.nextPassAt == .seconds(13))
        #expect(passes == 0)
        #expect(settings.reasonReads == 0) // a hide plans nothing
        #expect(lifecycle.state(of: "a") == .hidden)
    }

    @Test func theOnlyHiddenPageIsMostRecentlyUsedSoItIsNotFrozenThenDiscardedOnItsDeadline() throws {
        let settings = page("settings")
        lifecycle.show("a", page: Target(page: settings))
        lifecycle.hide("a", page: Target(page: settings))
        try runDuePass()
        #expect(lifecycle.state(of: "a") == .hidden)
        #expect(log.lines.isEmpty)
        // One deadline at a time: the discard at 300 s, not a repeating tick.
        #expect(lifecycle.nextPassAt == .seconds(300))
        try runDuePass()
        #expect(lifecycle.state(of: "a") == .discarded)
        #expect(log.lines == ["discard settings"])
        #expect(lifecycle.nextPassAt == nil)
    }

    @Test func anOlderHiddenPageFreezesOnceItIsNoLongerRecentlyVisible() throws {
        let history = page("history"), cloud = page("cloud")
        lifecycle.hide("h", page: Target(page: history))
        uptime.now = .seconds(5)
        lifecycle.hide("c", page: Target(page: cloud))
        // The earlier page lost mostRecentlyUsed now; it may freeze at 10 s.
        #expect(lifecycle.nextPassAt == .seconds(10))
        try runDuePass()
        #expect(lifecycle.state(of: "h") == .frozen)
        #expect(lifecycle.state(of: "c") == .hidden)
        #expect(log.lines == ["freeze history"])
    }

    @Test func showThawsAFrozenPageBeforeItReturnsSoTheRevealComesAfter() throws {
        let history = page("history"), cloud = page("cloud")
        lifecycle.hide("h", page: Target(page: history))
        uptime.now = .seconds(5)
        lifecycle.hide("c", page: Target(page: cloud))
        try runDuePass()
        #expect(lifecycle.state(of: "h") == .frozen)
        // The content lifecycle's reveal: show first, then the view draws.
        lifecycle.show("h", page: Target(page: history))
        log.lines.append("reveal history")
        #expect(log.lines == ["freeze history", "thaw history", "reveal history"])
        #expect(lifecycle.state(of: "h") == .active)
    }

    @Test func showOfARunningPageDoesNotThaw() {
        let settings = page("settings")
        lifecycle.hide("a", page: Target(page: settings))
        lifecycle.show("a", page: Target(page: settings))
        #expect(log.lines.isEmpty)
        #expect(lifecycle.state(of: "a") == .active)
    }

    @Test func aDiscardedPageThawsWhenShown() throws {
        let settings = page("settings")
        lifecycle.hide("a", page: Target(page: settings))
        uptime.now = .seconds(400)
        lifecycle.runPass()
        #expect(lifecycle.state(of: "a") == .discarded)
        lifecycle.show("a", page: Target(page: settings))
        #expect(log.lines == ["discard settings", "thaw settings"])
    }

    @Test func aFreezeBlockingReasonKeepsThePageRunning() throws {
        let history = page("history"), cloud = page("cloud")
        history.reasons = [.loading]
        lifecycle.hide("h", page: Target(page: history))
        uptime.now = .seconds(5)
        lifecycle.hide("c", page: Target(page: cloud))
        try runDuePass()
        #expect(lifecycle.state(of: "h") == .hidden)
        #expect(log.lines.isEmpty)
    }

    @Test func anOwnerReasonThawsAFrozenPageAtOnceAndDroppingItArmsAPass() throws {
        let history = page("history"), cloud = page("cloud")
        lifecycle.hide("h", page: Target(page: history))
        uptime.now = .seconds(5)
        lifecycle.hide("c", page: Target(page: cloud))
        try runDuePass()
        lifecycle.setKeepReasons([.audible], for: "h")
        #expect(lifecycle.state(of: "h") == .hidden)
        #expect(log.lines == ["freeze history", "thaw history"])
        uptime.now = .seconds(20)
        lifecycle.setKeepReasons([], for: "h")
        #expect(lifecycle.nextPassAt == .seconds(20))
        lifecycle.runPass()
        #expect(lifecycle.state(of: "h") == .frozen)
    }

    @Test func eventsTouchOnlyTheChangedPageAndAPassReadsOnlyHiddenPages() throws {
        let shown = (0..<100).map { page("p\($0)") }
        for (index, fake) in shown.enumerated() { lifecycle.show("k\(index)", page: Target(page: fake)) }
        let hiding = page("hiding")
        lifecycle.show("h", page: Target(page: hiding))
        lifecycle.hide("h", page: Target(page: hiding))
        #expect(shown.allSatisfy { $0.reasonReads == 0 })
        try runDuePass()
        #expect(shown.allSatisfy { $0.reasonReads == 0 })
        #expect(hiding.reasonReads == 1)
    }

    @Test func criticalPressureLooksAgainAtOnceAndDiscardsSooner() throws {
        let history = page("history"), cloud = page("cloud")
        lifecycle.hide("h", page: Target(page: history))
        uptime.now = .seconds(5)
        lifecycle.hide("c", page: Target(page: cloud))
        try runDuePass()
        uptime.now = .seconds(30)
        lifecycle.setPressure(.critical)
        #expect(lifecycle.nextPassAt == .seconds(30))
        lifecycle.runPass()
        // Chrome's urgent pace: one discard per pass, the longest hidden first, the next 5 s later.
        #expect(lifecycle.state(of: "h") == .discarded)
        #expect(lifecycle.state(of: "c") == .hidden)
        #expect(lifecycle.nextPassAt == .seconds(35))
        try runDuePass()
        #expect(lifecycle.state(of: "c") == .discarded)
        #expect(log.lines == ["freeze history", "discard history", "discard cloud"])
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
        uptime.now = .seconds(400)
        lifecycle.runPass()
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
        uptime.now = .seconds(400)
        lifecycle.runPass()
        #expect(lifecycle.state(of: "a") == .discarded)
        // The tab's view was made again (a restore) and hidden before it showed: no thaw of the old one.
        lifecycle.hide("a", page: Target(page: new))
        #expect(lifecycle.state(of: "a") == .hidden)
        #expect(log.lines == ["discard old"])
        lifecycle.forget(old)
        #expect(lifecycle.state(of: "a") == .hidden)
    }

    @Test func webUIHostOwnsOneLifecycleAndCloseForgetsThePage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let host = WebUIHost(chromium: nil, openPanel: nil,
                             memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()),
                             clock: PageTestClock.never)
        let descriptor = PageDescriptor(id: "test.page-lifecycle", resource: "page-lifecycle", processGroup: .viewer, namespaces: [])
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        let target = PageWebViewLifecycle(view)
        #expect(target.lifecycleGroup == "viewer")
        #expect(target.lifecycleKeepReasons.contains(.loading)) // no first paint yet
        host.lifecycle.hide("tab", page: target)
        #expect(host.lifecycle.state(of: "tab") == .hidden)
        host.close(view)
        #expect(host.lifecycle.state(of: "tab") == nil)
    }
}
