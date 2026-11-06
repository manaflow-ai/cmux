import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextDaemon
import CmuxNextFocus
import CmuxNextTestSupport
import Foundation
import Testing

/// NEWTAB PER-FRAME (STATUS 6416): a pane reported `contentPresented` to its window's focus on every
/// show of its selection, also when nothing it shows had changed. A strip update (a title, a busy dot)
/// queues a show of the same selection on the next frame (`PaneController.apply`), so a pane whose
/// strip observation fired every frame reduced focus every frame while idle: a New Tab page sent 272 of
/// the input journal's 300 entries, one per 16.7 ms, and pushed the key events out of the journal.
/// The report is for a change of what the pane shows (its tab, its content view, its window), once.
/// Runs a real `PaneController` in a window; the shows are the frames the presentation scheduler runs.
@Suite(.closesItsWindows)
@MainActor struct PaneContentPresentedOnChangeTests {
    final class Provider: InternalPageProvider {
        let page = InternalPageID(rawValue: "presented-once-test")
        var title: String { "Notes" }
        var symbol: String { "doc" }
        func makeView(for key: String, in window: WindowController?) -> NSView { NSView() }
    }

    /// The pane's `contentPresented` events the window's focus reduced.
    final class Reports {
        var count = 0
    }

    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, title: "~")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"presented-once-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// Lets the main actor run what is queued (observation steps): a fixed number of yields, no wait
    /// for time to pass.
    private static func drainMain() async {
        for _ in 0..<40 { await Task.yield() }
    }

    @Test(.timeLimit(.minutes(1)))
    func aPaneReportsItsContentPresentedOncePerChangeNotPerShow() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree())
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let provider = Provider()
        services.pages.register(provider)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        defer { withExtendedLifetime(services) { content.teardown(); window.close() } }
        content.contentView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView = content.contentView
        window.orderFrontRegardless()
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()
        let pane = try #require(content.panes.values.first)
        let pages = (0..<2).map { _ in services.pages.open(provider.page, in: pane.paneKey, of: store) }
        pane.syncStripFromStore()
        pane.applySelection(StripTabID(pages[0]))
        pane.showSelected()
        await Self.drainMain()
        #expect(pane.currentTabKey == pages[0])

        let reports = Reports()
        let paneKey = pane.paneKey
        let previous = state.focus.observer
        state.focus.observer = { observation in
            previous?(observation)
            if case .reduced(.contentPresented(let reported), _, _, _) = observation, reported == paneKey { reports.count += 1 }
        }
        defer { state.focus.observer = previous }
        var presented: Int { reports.count }

        // Sixty frames of strip updates that change nothing the pane shows: no report, no focus reduce.
        for _ in 0..<60 {
            pane.syncStripFromStore()
            pane.showSelected() // the frame the presentation scheduler runs for that update
        }
        #expect(presented == 0, "60 shows of the same content reported it presented \(presented) times")

        // Another tab shows: one report, and none for its later shows.
        pane.applySelection(StripTabID(pages[1]))
        pane.showSelected()
        for _ in 0..<10 { pane.showSelected() }
        #expect(presented == 1, "a switch to another tab and 10 shows of it reported \(presented) times")

        // Back to the first tab (its page view was made before): one report.
        pane.applySelection(StripTabID(pages[0]))
        pane.showSelected()
        pane.showSelected()
        #expect(presented == 2, "a switch back reported \(presented - 1) times")

        // The pane let its view go (the tab moved away and back): showing it again is a change.
        pane.surfaceWasDisplaced(pages[0])
        pane.showSelected()
        #expect(presented == 3, "a show after the view was let go reported \(presented - 2) times")
    }

    /// One chrome per pane (#32909 step B): the pane shows the same chrome view before and after the shown tab's page
    /// is replaced (a hibernated page woken, a deferred page started). The page is what takes the keyboard, so the
    /// new page is a change of what shows: focus applies again, or the keys go to the closed page's view.
    @Test(.timeLimit(.minutes(1)))
    func aPageReplacedUnderTheSharedChromeIsReportedPresented() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree())
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        defer { withExtendedLifetime(services) { content.teardown(); window.close() } }
        content.contentView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView = content.contentView
        window.orderFrontRegardless()
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()
        let pane = try #require(content.panes.values.first)
        let local = LocalBrowserTab.make(url: URL(string: "https://swap.example/"))
        let first = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: local.url))
        services.cache.install(first, for: local.id)
        state.localBrowserTabs[pane.paneKey].append(local)
        pane.syncStripFromStore()
        pane.applySelection(StripTabID(local.id))
        pane.showSelected()
        await Self.drainMain()
        #expect(pane.currentTabKey == local.id)

        let reports = Reports()
        let paneKey = pane.paneKey
        let previous = state.focus.observer
        state.focus.observer = { observation in
            previous?(observation)
            if case .reduced(.contentPresented(let reported), _, _, _) = observation, reported == paneKey { reports.count += 1 }
        }
        defer { state.focus.observer = previous }

        let woken = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: local.url))
        services.cache.swapPage(local.id, with: woken)
        pane.showSelected() // `onBrowserReady`: the panes showing the tab show it again
        #expect(services.cache.existingBrowser(local.id)?.chrome?.tab === woken, "the pane's chrome shows the new page")
        #expect(reports.count == 1, "the new page under the same chrome was reported presented \(reports.count) times")
        pane.showSelected()
        #expect(reports.count == 1, "a later show of the same page reported again")
    }

    /// The pane shows other content (a page tab): a change under its hidden browser chrome (the bound tab's page
    /// replaced, or that tab closed) changes nothing the pane shows, so focus is not applied again; and the chrome
    /// stays parked in the pane with the other browser tabs' pages in it.
    @Test(.timeLimit(.minutes(1)))
    func aHiddenBrowserChromeChangesNoPresentationAndStaysParked() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree())
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let provider = Provider()
        services.pages.register(provider)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        defer { withExtendedLifetime(services) { content.teardown(); window.close() } }
        content.contentView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView = content.contentView
        window.orderFrontRegardless()
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()
        let pane = try #require(content.panes.values.first)
        let tabs = ["a", "b", "c"].map { LocalBrowserTab.make(url: URL(string: "https://\($0).example/")) }
        for tab in tabs {
            services.cache.install(MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: tab.url)), for: tab.id)
            state.localBrowserTabs[pane.paneKey].append(tab)
        }
        let page = services.pages.open(provider.page, in: pane.paneKey, of: store)
        pane.syncStripFromStore()
        for key in tabs.map(\.id) + [page] {
            pane.applySelection(StripTabID(key))
            pane.showSelected()
        }
        await Self.drainMain()
        #expect(pane.currentTabKey == page)

        let reports = Reports()
        let paneKey = pane.paneKey
        let previous = state.focus.observer
        state.focus.observer = { observation in
            previous?(observation)
            if case .reduced(.contentPresented(let reported), _, _, _) = observation, reported == paneKey { reports.count += 1 }
        }
        defer { state.focus.observer = previous }

        // The chrome's bound tab (c, shown last) gets a new page while the page tab shows.
        services.cache.swapPage(tabs[2].id, with: MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: tabs[2].url)))
        pane.showSelected()
        #expect(reports.count == 0, "a page replaced under the hidden chrome was reported presented \(reports.count) times")

        // Tab c closes: the chrome lets it go; tabs a and b keep their pages parked in the window.
        state.localBrowserTabs[pane.paneKey].removeAll { $0.id == tabs[2].id }
        services.cache.release(tabs[2].id)
        pane.syncStripFromStore()
        pane.showSelected()
        #expect(reports.count == 0, "the hidden chrome's tab closing was reported presented")
        for tab in tabs.prefix(2) {
            #expect(services.cache.existingBrowser(tab.id)?.tab.contentView.window === window, "tab \(tab.id)'s page left the window")
        }
    }
}
