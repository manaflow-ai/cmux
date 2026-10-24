import AppKit
@testable import CmuxNextApp
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import Foundation
import Testing

/// The app's assembly of the freeze of hidden cmux pages (perf-lead.md F3): `browser.freezeHiddenTabs`
/// applied through the hibernation reaches the policy every page started through the app's page
/// host reports to. Before f20b6ea9927 the hibernation kept a policy but the host was made at launch
/// with none (set through an optional cast of a host that did not exist yet), so no cmux page ever
/// reported to it. A host or hibernation made with a policy of its own disconnects the setting the
/// same way: the pages freeze at the fallback 30 s whatever the file says. Both now come from one
/// seam, `AppServices.cmuxPages`, through `makeHibernation()` and `makeChromiumPageHost()` (the
/// host `AppDelegate` installs as `PageWebView.chromiumHosting`).
///
/// Chromium does not start in a unit test, so the page is a ``FakeChromiumPage`` whose host hands
/// it the freeze policy of the app's host, as the app's host does with its own pages. The policy
/// itself is tested in CmuxNextPagesTests/CmuxPageFreezingTests.swift.
@Suite(.serialized)
@MainActor
struct BrowserHibernationCmuxPagesTests {
    /// The app's assembly from the seams its launch uses.
    private struct Assembly {
        let services: AppServices
        let hibernation: BrowserHibernation
        let host: ChromiumPageHost
    }

    private let clock = SteppedClock()
    private let stage = PageTestWindow()
    private let root: URL

    init() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-hibernation-pages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    /// The app's hibernation and page host, on the test clock.
    private func assemble() -> Assembly {
        let services = AppServices(environment: AppEnvironment.current([:]), cmuxPages: CmuxPageFreezing(clock: clock))
        return Assembly(services: services, hibernation: services.makeHibernation(), host: services.makeChromiumPageHost())
    }

    /// A booted page in a pane the test hides, reporting to the app host's policy.
    private func bootedPage(_ hosting: FakeChromiumHosting) async throws -> (view: PageWebView, page: FakeChromiumPage, pane: NSView) {
        let pane = stage.show(NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        let descriptor = PageDescriptor(id: "test.hibernation-pages", resource: "hibernation-pages", namespaces: [])
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: hosting))
        view.chromiumClock = clock
        pane.addSubview(view)
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        view.chromiumSession?.reachedHost = true
        return (view, page, pane)
    }

    /// Steps the clock and runs the pass the policy's deadline would run.
    private func pass(after seconds: Int, _ policy: CmuxPageFreezing) {
        clock.advance(by: .seconds(seconds))
        policy.replan()
    }

    @Test func aPageFreezesOnTheGraceTheHibernationApplies() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = assemble()
        var setting = BrowserHibernationSetting.fallback
        setting.freezeSeconds = 120
        app.hibernation.apply(setting)
        let policy = try #require(app.host.freezePolicy as? CmuxPageFreezing)
        let hosting = FakeChromiumHosting()
        hosting.freezePolicy = policy
        let started = try await bootedPage(hosting)

        started.pane.isHidden = true
        pass(after: 31, policy) // past the fallback grace: a disconnected setting freezes here
        #expect(started.page.freezes.isEmpty)
        pass(after: 90, policy)
        #expect(started.page.freezes == [true])
        started.pane.isHidden = false
        started.view.close()
        withExtendedLifetime(app) {}
    }

    @Test func offThroughTheHibernationNeverFreezesAPage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = assemble()
        var setting = BrowserHibernationSetting.fallback
        setting.freezeSeconds = nil
        app.hibernation.apply(setting)
        let policy = try #require(app.host.freezePolicy as? CmuxPageFreezing)
        let hosting = FakeChromiumHosting()
        hosting.freezePolicy = policy
        let started = try await bootedPage(hosting)

        started.pane.isHidden = true
        pass(after: 3_600, policy)
        #expect(started.page.freezes.isEmpty)
        #expect(policy.waitingCount == 0)
        started.pane.isHidden = false
        started.view.close()
        withExtendedLifetime(app) {}
    }
}
