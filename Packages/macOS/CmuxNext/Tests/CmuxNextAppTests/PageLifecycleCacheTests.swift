import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextHibernation
@testable import CmuxNextPages
@testable import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The tab content cache feeds the page lifecycle (`pageLifecycle`): with only that
/// feature wired (no `memoryDiscardInternalPages`), a page tab mounts, so its reveal and conceal reach
/// the lifecycle; a reveal thaws a frozen page before the content shows; and a tab's release forgets
/// it. Driven through `TabContentCache.present`/`withdraw` with a stand-in pane, as `PaneController`
/// presents before it shows the view.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct PageLifecycleCacheTests {
    @Test func withOnlyPageLifecycleOnAPageTabsShowAndHideReachTheLifecycleAndReleaseForgetsIt() throws {
        let rig = try Rig()
        defer { rig.close() }
        let key = rig.openPageTab()
        #expect(rig.cache.contentOwners.isEmpty, "the test wired memoryDiscardInternalPages")
        let view = try #require(rig.services.pages.view(for: key))
        #expect(view.content is PageWebView)

        rig.cache.present(key, by: rig.pane, presence: .visible)
        #expect(rig.cache.phase(of: key) == .mountedVisible, "the page tab never mounted: no reveal reaches the lifecycle")
        #expect(rig.lifecycle.state(of: key) == .active)

        rig.cache.withdraw(key, by: rig.pane)
        #expect(rig.cache.phase(of: key) == .mountedHidden)
        #expect(rig.lifecycle.state(of: key) == .hidden)
        #expect(rig.lifecycle.nextPassAt == .seconds(10))

        rig.cache.present(key, by: rig.pane, presence: .visible)
        #expect(rig.lifecycle.state(of: key) == .active)

        rig.cache.release(key)
        #expect(rig.lifecycle.state(of: key) == nil, "the closed tab's page stayed in the lifecycle")
        #expect(rig.lifecycle.pageCount == 0)
    }

    /// `reveal` thaws first: when the lifecycle thaws the page, the tab's content has not been made
    /// visible yet (its `setContentVisible(true)` comes after, in the same reveal).
    @Test func aFrozenPageThawsInItsRevealBeforeItsContentIsVisible() throws {
        let rig = try Rig()
        defer { rig.close() }
        let engine = MockBrowserEngine()
        let first = engine.makeMockTab(BrowserTabConfiguration()), second = engine.makeMockTab(BrowserTabConfiguration())
        let (a, b) = (first.id.rawValue, second.id.rawValue)
        _ = rig.cache.install(first, for: a)
        _ = rig.cache.install(second, for: b)
        let log = OrderLog()
        let targets = [a: OrderTarget(name: "a", tab: first, log: log), b: OrderTarget(name: "b", tab: second, log: log)]
        rig.lifecycle.pageOfTab = { targets[$0] }

        rig.cache.present(a, by: rig.pane, presence: .visible)
        rig.cache.withdraw(a, by: rig.pane)
        rig.advance(to: .seconds(5))
        rig.cache.present(b, by: rig.pane, presence: .visible)
        rig.cache.withdraw(b, by: rig.pane)
        rig.advance(to: .seconds(10))
        rig.lifecycle.runPass()
        #expect(rig.lifecycle.state(of: a) == .frozen)

        rig.cache.present(a, by: rig.pane, presence: .visible)
        #expect(log.lines == ["keep a", "keep b", "freeze a", "thaw a"])
        #expect(log.lastCommandAtThaw == .occlude(true), "the content was visible before its page thawed")
        #expect(first.commands.last == .occlude(false), "the reveal did not show the content")
        #expect(rig.lifecycle.state(of: a) == .active)
        rig.cache.release(a)
        rig.cache.release(b)
    }

    /// `conceal` hands the hide to the page lifecycle first: the page is pictured while its content
    /// still shows, before the engine is told it is hidden (a hidden page has no frame to picture).
    @Test func theHidePicturesThePageBeforeItsContentIsHidden() throws {
        let rig = try Rig()
        defer { rig.close() }
        let engine = MockBrowserEngine()
        let tab = engine.makeMockTab(BrowserTabConfiguration())
        let key = tab.id.rawValue
        _ = rig.cache.install(tab, for: key)
        let log = OrderLog()
        let target = OrderTarget(name: "a", tab: tab, log: log)
        rig.lifecycle.pageOfTab = { $0 == key ? target : nil }

        rig.cache.present(key, by: rig.pane, presence: .visible)
        rig.cache.withdraw(key, by: rig.pane)
        #expect(log.lines == ["keep a"])
        #expect(log.lastCommandAtKeep == .occlude(false), "the content was hidden before its picture was taken")
        #expect(tab.commands.last == .occlude(true), "the conceal did not hide the content")
        rig.cache.release(key)
    }

    // MARK: Rig

    /// App services with the page lifecycle installed as `registerPageLifecycle` does, on a deadline
    /// scheduler whose uptime only the test moves (its wake never fires: a test runs the pass).
    @MainActor final class Rig {
        let services: AppServices
        let lifecycle: PageLifecycle
        let pane = Pane()
        let host: WebUIHost
        let folder: URL
        var cache: TabContentCache { services.cache }
        private let uptime: RigUptime

        init() throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            let uptime = RigUptime()
            self.uptime = uptime
            let queue = MainWakeUpQueue(energy: EnergyPolicySource(), ledger: WakeupLedger(uptime: { 0 }),
                                        uptime: { uptime.now }) { _ in RigWakeUpTimer() }
            lifecycle = PageLifecycle(deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget()), queue: queue))
            AppMemoryConsumers(services: services).installPageLifecycle(lifecycle)
            host = WebUIHost(chromium: nil, openPanel: nil, memory: ManualMemoryLevelRegistry(), deadlines: .testing())
            folder = FileManager.default.temporaryDirectory.appending(path: "page-lifecycle-cache-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("<!doctype html><title>Lifecycle</title>".utf8).write(to: folder.appending(path: "index.html"))
        }

        /// A page tab whose view is a cmux page.
        func openPageTab() -> String {
            let (host, folder) = (host, folder)
            let provider = WebPageProvider {
                let descriptor = PageDescriptor(id: "test.lifecycle-cache", resource: "lifecycle-cache", processGroup: .solo, namespaces: [])
                return host.open(PageOpenRequest(descriptor: descriptor, root: folder, routes: [])) ?? NSView()
            }
            services.pages.register(provider)
            return services.pages.open(provider.page, in: "pane-lifecycle-test", of: DaemonStore())
        }

        func advance(to time: Duration) { uptime.now = time.nanosecondCount }

        func close() { try? FileManager.default.removeItem(at: folder) }
    }

    @MainActor final class Pane: SurfacePresenter {
        func surfaceWasDisplaced(_ key: String) {}
    }

    @MainActor final class WebPageProvider: InternalPageProvider {
        let page = InternalPageID(rawValue: "lifecycle-cache-test")
        let title = "Lifecycle test"
        let symbol = "doc"
        private let make: () -> NSView

        init(_ make: @escaping () -> NSView) {
            self.make = make
        }

        func makeView(for key: String, in window: WindowController?) -> NSView { make() }
    }

    @MainActor final class OrderLog {
        var lines: [String] = []
        var lastCommandAtThaw: MockBrowserTab.Command?
        var lastCommandAtKeep: MockBrowserTab.Command?
    }

    /// A page target over a mock tab: it logs each step, and the tab's last command when it thaws.
    @MainActor struct OrderTarget: PageLifecycleTarget {
        let name: String
        let tab: MockBrowserTab
        let log: OrderLog
        var object: AnyObject? { tab }
        var lifecycleGroup: String? { nil }
        var lifecycleKeepReasons: Set<PageLifecyclePlanner.KeepReason> { [] }
        func reportsReasonChanges(to lifecycle: PageLifecycle) {}
        func keepHideSnapshot() {
            log.lines.append("keep \(name)")
            log.lastCommandAtKeep = tab.commands.last
        }

        func dropHideSnapshot() {}
        func freeze() -> Bool {
            log.lines.append("freeze \(name)")
            return true
        }
        func discard() -> Bool {
            log.lines.append("discard \(name)")
            return true
        }

        func thaw() {
            log.lines.append("thaw \(name)")
            log.lastCommandAtThaw = tab.commands.last
        }
    }
}

/// A timer the queue arms and parks; nothing fires it.
private nonisolated final class RigWakeUpTimer: MainWakeUpTimer {
    func arm(at date: UInt64, tolerance: UInt64, now: UInt64) {}
    func park() {}
}

/// The rig's uptime in ns: the queue reads it from any thread, only the test's main actor moves it.
private nonisolated final class RigUptime: Sendable {
    private let value = Atomic<UInt64>(0)

    var now: UInt64 {
        get { value.load(ordering: .relaxed) }
        set { value.store(newValue, ordering: .relaxed) }
    }
}
