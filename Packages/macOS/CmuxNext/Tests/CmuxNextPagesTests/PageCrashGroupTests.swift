import AppKit
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// A renderer crash with the page lifecycle on (p13-webui.md 3.C): shown pages reload
/// once, hidden pages are marked and load when they show, and pages that really share a renderer share
/// its crash budget (3 per 600 s), so one death of a renderer that held 5 pages counts once and a crash
/// loop stops. A page in a renderer of its own keeps a budget of its own.
@MainActor @Suite(.serialized)
struct PageCrashGroupTests {
    private let root: URL
    /// Agent pages: WebKit puts them in the host's shared processes (``PageEngineOptions/sharesWebKitProcess``).
    private let agent = PageDescriptor(id: "test.crash-agent", resource: "crash-agent", processGroup: .agent, namespaces: [])
    private let shared = PageEngineOptions(sharesWebKitProcess: true)
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

    /// The renderer each page's engine names (the host's ``PageCrashGroups/rendererID``).
    @MainActor private final class Renderers {
        var ids: [ObjectIdentifier: PageRendererID] = [:]

        /// `view` commits a document in `renderer`, as its engine reports one.
        func commit(_ view: PageWebView, in renderer: PageRendererID) {
            ids[ObjectIdentifier(view)] = renderer
            view.documentCommitted()
        }
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-crash-group-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    /// A host (WebKit only without `chromium`); with `lifecycle`, as the app makes it with `pageLifecycle` on.
    /// `webKitGroups`: every page of a sharing group joins the host's WebKit groups (`webKitPageProcessGroups`).
    private func makeHost(lifecycle: Bool, rig: LifecycleDeadlineRig, renderers: Renderers = Renderers(),
                          chromium: FakeChromiumHosting? = nil, chromiumGroups: Bool = false,
                          webKitGroups: Bool = false) -> WebUIHost {
        let host = WebUIHost(chromium: chromium, openPanel: nil,
                             memory: QuietMemoryRegistry(),
                             deadlines: LifecycleDeadlineRig.never,
                             processGroups: WebProcessGroups(pagesPerProcess: 8, groupsEverySharingPage: webKitGroups))
        if lifecycle { host.lifecycle = PageLifecycle(deadlines: rig.scheduler) }
        host.crashGroups = PageCrashGroups(chromiumSharesByGroup: chromiumGroups) { renderers.ids[ObjectIdentifier($0)] }
        return host
    }

    /// `count` pages of `descriptor` in one window, every one but the first hidden as a background tab
    /// is. With `notice`, each reports its crashes to `log` (its host shows the crash notice).
    private func openPages(_ count: Int, of descriptor: PageDescriptor, options: PageEngineOptions = .standard,
                           host: WebUIHost, log: CrashLog, notice: Bool = true,
                           clock: @escaping () -> Date) async throws -> (NSWindow, [PageWebView]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = container
        var views: [PageWebView] = []
        for index in 0..<count {
            let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [], options: options)))
            await view.chromiumStart?.value
            view.frame = container.bounds
            view.now = clock
            if notice { view.onCrash = { page, reloading in log.reports.append((ObjectIdentifier(page), reloading)) } }
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

    // MARK: Pages that share a renderer

    @Test func fivePagesOfOneRendererWithOneShownGiveOneReloadAndTheHiddenOnesReloadWhenShown() async throws {
        let rig = LifecycleDeadlineRig(), renderers = Renderers()
        let host = makeHost(lifecycle: true, rig: rig, renderers: renderers)
        let log = CrashLog()
        var now = start
        let (window, views) = try await openPages(5, of: agent, options: shared, host: host, log: log) { now }
        defer { close(views, host: host) }
        let shown = views[0], hidden = Array(views.dropFirst())
        for view in views { renderers.commit(view, in: .webKit(pid: 100)) }

        // The renderer dies: every page it ran reports it, seconds apart (a stalled main thread).
        for view in views {
            view.contentProcessTerminated()
            now += 5
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
        #expect(host.crashGroups.allowsReload(.group(.webKit, .agent), at: now))
        withExtendedLifetime(window) {}
    }

    @Test func theGroupCapStopsACrashLoopAndAHiddenPageThatWaitedDoesNotReloadPastIt() async throws {
        let rig = LifecycleDeadlineRig(), renderers = Renderers()
        let host = makeHost(lifecycle: true, rig: rig, renderers: renderers)
        let log = CrashLog()
        var now = start
        let (window, views) = try await openPages(3, of: agent, options: shared, host: host, log: log) { now }
        defer { close(views, host: host) }
        let shown = views[0], waiting = views[1], later = views[2]
        for view in views { renderers.commit(view, in: .webKit(pid: 100)) }

        // One death takes the shown page and a hidden one; the shown page then crashes as it loads,
        // each time in a new renderer.
        shown.contentProcessTerminated()
        waiting.contentProcessTerminated()
        #expect(waiting.crash.needsReload)
        for pid: Int32 in 101...103 {
            now += 30
            renderers.commit(shown, in: .webKit(pid: pid))
            shown.contentProcessTerminated()
        }
        #expect(log.reloading(of: shown) == [true, true, true, false], "the group's 4th death in 600 s still reloaded")
        #expect(shown.crash.reloads == 3)
        #expect(!shown.loadState.isLoading, "a page that stopped reloading still reads as loading")

        // Another page of the group loses its renderer past the cap: no reload, now or at its show.
        renderers.commit(later, in: .webKit(pid: 200))
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
        renderers.commit(shown, in: .webKit(pid: 104))
        now += 1
        shown.contentProcessTerminated()
        #expect(log.reloading(of: shown).last == true)
        #expect(shown.crash.reloads == 4)
        withExtendedLifetime(window) {}
    }

    @Test(arguments: [false, true])
    func chromiumPagesShareABudgetOnlyWhileChromiumGroupsTheirRenderers(grouped: Bool) async throws {
        let rig = LifecycleDeadlineRig(), renderers = Renderers()
        let host = makeHost(lifecycle: true, rig: rig, renderers: renderers, chromium: FakeChromiumHosting(), chromiumGroups: grouped)
        let log = CrashLog()
        var now = start
        let (window, views) = try await openPages(2, of: privileged, host: host, log: log) { now }
        defer { close(views, host: host) }
        let looping = views[0], other = views[1]
        #expect(views.allSatisfy { $0.chromiumPage != nil })
        for view in views { renderers.commit(view, in: .chromium(client: 7)) }
        looping.contentProcessTerminated()
        other.contentProcessTerminated()
        for client: Int32 in 8...10 {
            now += 30
            renderers.commit(looping, in: .chromium(client: client))
            looping.contentProcessTerminated()
        }
        #expect(log.reloading(of: looping) == [true, true, true, false])
        renderers.commit(other, in: .chromium(client: 11))
        now += 30
        other.contentProcessTerminated()
        // Grouped, the death of renderer 7 counted once and the loop used the rest; apart, the other
        // page's budget holds only its own two crashes.
        #expect(log.reloading(of: other) == [true, !grouped])
        withExtendedLifetime(window) {}
    }

    /// With `webKitPageProcessGroups` the privileged WebKit pages share a WebContent process, so they
    /// share its crash budget as the agent pages do; off, each keeps its own.
    @Test(arguments: [false, true])
    func privilegedWebKitPagesShareABudgetOnlyInTheHostsWebKitGroups(grouped: Bool) async throws {
        let rig = LifecycleDeadlineRig(), renderers = Renderers()
        let host = makeHost(lifecycle: true, rig: rig, renderers: renderers, webKitGroups: grouped)
        let log = CrashLog()
        var now = start
        let (window, views) = try await openPages(2, of: privileged, host: host, log: log) { now }
        defer { close(views, host: host) }
        let looping = views[0], other = views[1]
        #expect(views.allSatisfy { $0.crash.sharesWebKitProcess == grouped })
        for view in views { renderers.commit(view, in: .webKit(pid: 100)) }
        looping.contentProcessTerminated()
        other.contentProcessTerminated()
        #expect(looping.crash.reloads == 1, "the shown page of the dead process did not reload")
        #expect(other.crash.needsReload, "the hidden page of the dead process does not load at its show")
        for pid: Int32 in 101...103 {
            now += 30
            renderers.commit(looping, in: .webKit(pid: pid))
            looping.contentProcessTerminated()
        }
        #expect(log.reloading(of: looping) == [true, true, true, false])
        renderers.commit(other, in: .webKit(pid: 200))
        now += 30
        other.contentProcessTerminated()
        // Grouped, the death of process 100 counted once and the loop used the rest; apart, the other
        // page's budget holds only its own two crashes.
        #expect(log.reloading(of: other) == [true, !grouped])
        withExtendedLifetime(window) {}
    }

    // MARK: Pages in renderers of their own

    @Test func twoPrivilegedPagesInSeparateRenderersKeepSeparateBudgets() async throws {
        let rig = LifecycleDeadlineRig(), renderers = Renderers()
        let host = makeHost(lifecycle: true, rig: rig, renderers: renderers)
        let log = CrashLog()
        var now = start
        let (window, views) = try await openPages(2, of: privileged, host: host, log: log) { now }
        defer { close(views, host: host) }
        renderers.commit(views[1], in: .webKit(pid: 200))
        for pid: Int32 in 100...103 {
            renderers.commit(views[0], in: .webKit(pid: pid))
            views[0].contentProcessTerminated()
            now += 1
        }
        #expect(log.reloading(of: views[0]) == [true, true, true, false])
        views[1].contentProcessTerminated()
        #expect(log.reloading(of: views[1]) == [true], "a page in its own renderer ran out of another page's budget")
        withExtendedLifetime(window) {}
    }

    @Test func aPageWhoseHostShowsNoCrashNoticeKeepsItsOwnBudget() async throws {
        let rig = LifecycleDeadlineRig(), renderers = Renderers()
        let host = makeHost(lifecycle: true, rig: rig, renderers: renderers)
        let log = CrashLog()
        var now = start
        let (window, views) = try await openPages(2, of: agent, options: shared, host: host, log: log, notice: false) { now }
        defer { close(views, host: host) }
        let looping = views[0], other = views[1]
        renderers.commit(other, in: .webKit(pid: 200))
        for pid: Int32 in 100...103 {
            renderers.commit(looping, in: .webKit(pid: pid))
            looping.contentProcessTerminated()
            now += 1
        }
        #expect(looping.crash.reloads == 3)
        // Nothing could bring it back if another page's loop stopped it.
        other.contentProcessTerminated()
        #expect(other.crash.needsReload, "a page no host can recover was stopped by another page's crash loop")
        withExtendedLifetime(window) {}
    }

    @Test func theBudgetComesBackAfterTheWindow() async throws {
        let rig = LifecycleDeadlineRig()
        let host = makeHost(lifecycle: true, rig: rig)
        let log = CrashLog()
        var now = start
        let (window, views) = try await openPages(1, of: privileged, host: host, log: log) { now }
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

    @Test func soloPagesKeepABudgetEachAndAClosedOneLeavesNone() async throws {
        let rig = LifecycleDeadlineRig()
        let host = makeHost(lifecycle: true, rig: rig)
        let log = CrashLog()
        var now = start
        let (window, views) = try await openPages(2, of: solo, host: host, log: log) { now }
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
        #expect(host.crashGroups.allowsReload(.page(ObjectIdentifier(views[0])), at: now), "a closed page's budget stayed")
        withExtendedLifetime(window) {}
    }

    @Test func withoutThePageLifecycleAHiddenPageReloadsAtOnceOnItsOwnBudget() async throws {
        let rig = LifecycleDeadlineRig()
        let host = makeHost(lifecycle: false, rig: rig)
        let log = CrashLog()
        var now = start
        let (window, views) = try await openPages(2, of: agent, options: shared, host: host, log: log) { now }
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

    // MARK: Loads while a page waits for its show

    @Test func aRouteOpenedWhileThePageWaitsLoadsOnceAtTheShow() async throws {
        let rig = LifecycleDeadlineRig()
        let host = makeHost(lifecycle: true, rig: rig, chromium: FakeChromiumHosting())
        let log = CrashLog()
        let (window, views) = try await openPages(2, of: privileged, host: host, log: log) { start }
        defer { close(views, host: host) }
        let view = views[1], page = try #require(view.chromiumPage as? FakeChromiumPage)
        let loadsBefore = page.loaded.count
        view.contentProcessTerminated()
        #expect(view.crash.needsReload)

        view.open(route: "/later")
        #expect(page.loaded.count == loadsBefore && page.reloads == 0, "a hidden page loaded before its show")
        view.isHidden = false
        #expect(page.loaded.count == loadsBefore + 1, "the show made no load, or more than one")
        #expect(page.loaded.last == privileged.url(route: "#/later"))
        #expect(page.reloads == 0, "the show reloaded the old document over the route it loaded")
        #expect(view.crash.reloads == 1 && !view.crash.needsReload)
        view.isHidden = true
        view.isHidden = false
        #expect(page.loaded.count == loadsBefore + 1 && page.reloads == 0)
        withExtendedLifetime(window) {}
    }

    @Test func aReloadAskedForWhileThePageWaitsIsTheShowsOneLoad() async throws {
        let rig = LifecycleDeadlineRig()
        let host = makeHost(lifecycle: true, rig: rig, chromium: FakeChromiumHosting())
        let log = CrashLog()
        let (window, views) = try await openPages(2, of: privileged, host: host, log: log) { start }
        defer { close(views, host: host) }
        let view = views[1], page = try #require(view.chromiumPage as? FakeChromiumPage)
        let loadsBefore = page.loaded.count
        view.contentProcessTerminated()
        view.reload()
        #expect(page.reloads == 0, "a hidden page reloaded before its show")
        view.isHidden = false
        #expect(page.reloads == 1 && page.loaded.count == loadsBefore)
        withExtendedLifetime(window) {}
    }

    // MARK: Budget

    @Test func oneDeathReportedByEveryPageOfTheRendererCountsOnceHoweverLate() {
        var budget = PageCrashReloads()
        for crash in 0..<3 {
            let renderer = PageRendererID.webKit(pid: Int32(100 + crash))
            let at = start + Double(crash) * 60
            for page in 0..<5 {
                // `shouldReload` is mutating: read it before `#expect`, which passes its subject immutably.
                let reloads = budget.shouldReload(at: at + Double(page) * 10, renderer: renderer)
                #expect(reloads, "crash \(crash), page \(page)")
            }
        }
        #expect(budget.allowsReload(at: start + 200))
        let fourth = start + 240
        let fourthDeath = budget.shouldReload(at: fourth, renderer: .webKit(pid: 103))
        let fourthDeathLater = budget.shouldReload(at: fourth + 30, renderer: .webKit(pid: 103))
        #expect(!fourthDeath)
        #expect(!fourthDeathLater, "a page of the 4th death reloaded")
        #expect(!budget.allowsReload(at: fourth + 31))
    }

    @Test func twoRenderersDyingTogetherAreTwoDeaths() {
        var budget = PageCrashReloads()
        let answers = (0..<4).map { budget.shouldReload(at: start + Double($0) * 0.01, renderer: .chromium(client: Int32($0))) }
        #expect(answers == [true, true, true, false], "deaths of separate renderers close in time were merged")
    }

    @Test func crashesWithNoRendererEachCount() {
        var budget = PageCrashReloads()
        let answers = (0..<4).map { budget.shouldReload(at: start + Double($0) * 0.2) }
        #expect(answers == [true, true, true, false], "a fast crash loop of one page was taken for one death")
    }

    @Test func aRendererThatCommittedAgainDiesAsAnotherProcess() {
        var budget = PageCrashReloads()
        let pid = PageRendererID.webKit(pid: 100)
        var answers: [Bool] = []
        for crash in 0..<4 {
            budget.rendererCommitted(pid) // the system reused the pid for a new WebContent process
            answers.append(budget.shouldReload(at: start + Double(crash), renderer: pid))
        }
        #expect(answers == [true, true, true, false], "a reused pid's death was taken for the old one")
    }
}
