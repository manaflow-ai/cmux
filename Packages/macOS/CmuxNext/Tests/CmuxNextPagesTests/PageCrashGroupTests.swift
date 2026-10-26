import AppKit
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextPages
import Foundation
import Testing

/// A renderer crash with the page lifecycle on (p13-webui-039, p13-webui.md 3.C): shown pages reload
/// once, hidden pages are marked and reload when they show, and the crash budget (3 per 600 s) is per
/// renderer group, so one death of a renderer that held 5 pages counts once and a crash loop stops.
@MainActor @Suite(.serialized)
struct PageCrashGroupTests {
    private let root: URL
    private let privileged = PageDescriptor(id: "test.crash-group", resource: "crash-group", processGroup: .privileged, namespaces: [])
    private let solo = PageDescriptor(id: "test.crash-solo", resource: "crash-solo", processGroup: .solo, namespaces: [])
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// What each page told its host (``PageWebView/onCrash``), in order.
    private final class CrashLog {
        var reports: [(page: ObjectIdentifier, reloading: Bool)] = []
        func reloading(of page: PageWebView) -> [Bool] {
            reports.filter { $0.page == ObjectIdentifier(page) }.map { $0.reloading }
        }
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-crash-group-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    /// A WebKit host; with `lifecycle`, as the app makes it with `pageLifecycle` on.
    private func makeHost(lifecycle: Bool, rig: LifecycleDeadlineRig) -> WebUIHost {
        let host = WebUIHost(chromium: nil, openPanel: nil,
                             memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()),
                             clock: PageTestClock.never)
        if lifecycle { host.lifecycle = PageLifecycle(deadlines: rig.scheduler) }
        return host
    }

    /// `count` pages of `descriptor` in one window, every one but the first hidden as a background tab
    /// is, each reporting its crashes to `log` at the time `clock` holds.
    private func openPages(_ count: Int, of descriptor: PageDescriptor, host: WebUIHost, log: CrashLog,
                           clock: @escaping () -> Date) throws -> (NSWindow, [PageWebView]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = container
        var views: [PageWebView] = []
        for index in 0..<count {
            let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
            view.frame = container.bounds
            view.now = clock
            view.onCrash = { page, reloading in log.reports.append((ObjectIdentifier(page), reloading)) }
            view.isHidden = index > 0
            container.addSubview(view)
            views.append(view)
        }
        return (window, views)
    }

    private func close(_ views: [PageWebView], host: WebUIHost) {
        for view in views { host.close(view) }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Pages

    @Test func fivePagesOfOneRendererWithOneShownGiveOneReloadAndTheHiddenOnesReloadWhenShown() throws {
        let rig = LifecycleDeadlineRig()
        let host = makeHost(lifecycle: true, rig: rig)
        let log = CrashLog()
        var now = start
        let (window, views) = try openPages(5, of: privileged, host: host, log: log) { now }
        defer { close(views, host: host) }
        let shown = views[0], hidden = Array(views.dropFirst())

        // The renderer dies: every page it ran reports it, in one burst.
        for view in views {
            view.contentProcessTerminated()
            now += 0.01
        }
        #expect(views.map(\.crash.reloads).reduce(0, +) == 1, "5 pages with 1 shown reloaded more than once")
        #expect(shown.crash.reloads == 1)
        #expect(!shown.crash.needsReload)
        #expect(hidden.allSatisfy { $0.crash.needsReload && $0.crash.reloads == 0 })
        #expect(hidden.allSatisfy { !$0.loadState.isLoading }, "a hidden page waiting for its show held the lifecycle as loading")
        #expect(log.reports.count == 5 && log.reports.allSatisfy { $0.reloading }, "no page of a first crash stops")

        // A tab switch shows one: it reloads in its show, the others still wait.
        hidden[0].isHidden = false
        #expect(hidden[0].crash.reloads == 1)
        #expect(!hidden[0].crash.needsReload)
        #expect(hidden[0].loadState.isLoading)
        #expect(hidden.dropFirst().allSatisfy { $0.crash.needsReload && $0.crash.reloads == 0 })
        // Shown again later: no second reload.
        hidden[0].isHidden = true
        hidden[0].isHidden = false
        #expect(hidden[0].crash.reloads == 1)
        #expect(log.reports.count == 5, "a reload on show is not another crash report")
        withExtendedLifetime(window) {}
    }

    @Test func theGroupCapStopsACrashLoopAndAHiddenPageThatWaitedDoesNotReloadPastIt() throws {
        let rig = LifecycleDeadlineRig()
        let host = makeHost(lifecycle: true, rig: rig)
        let log = CrashLog()
        var now = start
        let (window, views) = try openPages(3, of: privileged, host: host, log: log) { now }
        defer { close(views, host: host) }
        let shown = views[0], waiting = views[1], later = views[2]

        // One death takes the shown page and a hidden one; the shown page then crashes as it loads.
        shown.contentProcessTerminated()
        waiting.contentProcessTerminated()
        #expect(waiting.crash.needsReload)
        for _ in 0..<3 {
            now += 30
            shown.contentProcessTerminated()
        }
        #expect(log.reloading(of: shown) == [true, true, true, false], "the group's 4th crash in 600 s still reloaded")
        #expect(shown.crash.reloads == 3)
        #expect(!shown.loadState.isLoading, "a page that stopped reloading still reads as loading")

        // Another page of the group crashes past the cap: no reload, now or at its show.
        now += 30
        later.contentProcessTerminated()
        #expect(log.reloading(of: later) == [false])
        #expect(!later.crash.needsReload)
        later.isHidden = false
        #expect(later.crash.reloads == 0)

        // The page that waited shows after the cap: it does not load into the crashing group, and
        // its host hears that it stopped (its crash notice).
        waiting.isHidden = false
        #expect(waiting.crash.reloads == 0)
        #expect(!waiting.crash.needsReload)
        #expect(log.reloading(of: waiting) == [true, false])

        // The person's Reload forgives the group: the next crash reloads again.
        shown.reloadAfterCrashes()
        now += 1
        shown.contentProcessTerminated()
        #expect(log.reloading(of: shown).last == true)
        #expect(shown.crash.reloads == 4)
        withExtendedLifetime(window) {}
    }

    @Test func theBudgetComesBackAfterTheWindow() throws {
        let rig = LifecycleDeadlineRig()
        let host = makeHost(lifecycle: true, rig: rig)
        let log = CrashLog()
        var now = start
        let (window, views) = try openPages(1, of: privileged, host: host, log: log) { now }
        defer { close(views, host: host) }
        for _ in 0..<4 {
            views[0].contentProcessTerminated()
            now += 10
        }
        #expect(log.reloading(of: views[0]) == [true, true, true, false])
        now = start + PageCrashReloads.window + 45
        views[0].contentProcessTerminated()
        #expect(log.reloading(of: views[0]).last == true, "crashes older than the window still counted")
        withExtendedLifetime(window) {}
    }

    @Test func soloPagesKeepABudgetEachAndAClosedOneLeavesNone() throws {
        let rig = LifecycleDeadlineRig()
        let host = makeHost(lifecycle: true, rig: rig)
        let log = CrashLog()
        var now = start
        let (window, views) = try openPages(2, of: solo, host: host, log: log) { now }
        defer { close(views, host: host) }
        views[1].isHidden = false
        for _ in 0..<4 {
            views[0].contentProcessTerminated()
            now += 1
        }
        #expect(log.reloading(of: views[0]) == [true, true, true, false])
        views[1].contentProcessTerminated()
        #expect(log.reloading(of: views[1]) == [true], "a solo page ran out of another page's budget")
        host.close(views[0])
        #expect(host.crashGroups.allowsReload(of: ObjectIdentifier(views[0]), in: .solo, at: now), "a closed page's budget stayed")
        withExtendedLifetime(window) {}
    }

    @Test func withoutThePageLifecycleAHiddenPageReloadsAtOnceOnItsOwnBudget() throws {
        let rig = LifecycleDeadlineRig()
        let host = makeHost(lifecycle: false, rig: rig)
        let log = CrashLog()
        var now = start
        let (window, views) = try openPages(2, of: privileged, host: host, log: log) { now }
        defer { close(views, host: host) }
        views[1].contentProcessTerminated()
        #expect(views[1].crash.reloads == 1)
        #expect(!views[1].crash.needsReload)
        for _ in 0..<3 {
            now += 30
            views[0].contentProcessTerminated()
        }
        // The other page of the group keeps its own budget.
        #expect(log.reloading(of: views[0]) == [true, true, true])
        withExtendedLifetime(window) {}
    }

    // MARK: Budget

    @Test func oneDeathReportedByEveryPageOfTheRendererCountsOnce() {
        let pages = (0..<5).map { _ in NSObject() }
        var budget = PageCrashReloads()
        for crash in 0..<3 {
            let at = start + Double(crash) * 60
            for (index, page) in pages.enumerated() {
                #expect(budget.shouldReload(at: at + Double(index) * 0.1, page: ObjectIdentifier(page)), "crash \(crash), page \(index)")
            }
        }
        #expect(budget.allowsReload(at: start + 200))
        let fourth = start + 240
        #expect(!budget.shouldReload(at: fourth, page: ObjectIdentifier(pages[0])))
        #expect(!budget.shouldReload(at: fourth + 0.1, page: ObjectIdentifier(pages[1])), "a page of the 4th death reloaded")
        #expect(!budget.allowsReload(at: fourth + 1))
    }

    @Test func onePageCrashingAgainSoonIsANewCrash() {
        let page = ObjectIdentifier(NSObject())
        var budget = PageCrashReloads()
        let answers = (0..<4).map { budget.shouldReload(at: start + Double($0) * 0.2, page: page) }
        #expect(answers == [true, true, true, false], "a fast crash loop of one page was taken for one death")
    }
}
