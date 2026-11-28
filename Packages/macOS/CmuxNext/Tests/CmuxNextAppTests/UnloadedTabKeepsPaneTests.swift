import AppKit
import CmuxNextAgentPane
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextBrowserTabs
@testable import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextTestSupport
import Foundation
import Testing

/// "when i click on an unloaded tab of anything at all the whole pane re-renders still on this version" and "likewise
/// when i move one tab completely to another pane, the original pane flickers a re-render" (Leo, 2026-11-22). A switch to
/// a tab with no content yet (restored at launch, opened in the background, hibernated) went through
/// `PaneController.presentSelection`'s first-visit path, which emptied the pane at once and made the tab's content on the
/// next frame: a frame of the bare pane between the two tabs, for every kind of tab. A tab moved out of a pane left it
/// empty the same way until the frame after, when the neighbor it selected had no content yet. The pane now keeps what it
/// shows until the new content is in, and a pane left with nothing shows its selection in the same turn.
@Suite(.serialized, .closesItsWindows)
@MainActor struct UnloadedTabKeepsPaneTests {
    private static func tree(coldBrowser: Bool = false, agentTab: Bool = false) -> DaemonTree {
        var third = TabSnapshot(surface: SurfaceID(rawValue: 3), title: "~")
        if agentTab {
            third = TabSnapshot(surface: SurfaceID(rawValue: 3), kind: .conversation, title: "Chat")
            third.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: AgentSessionRef.host(installID: "cold-tab-test")))
        }
        let tabs = [TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .browser, url: URL.historyPageString,
                                browserRenderer: "frontend", browserEngine: "webkit"),
                    TabSnapshot(surface: SurfaceID(rawValue: 2), kind: .browser, title: "Blank", url: coldBrowser ? "https://example.com/cold" : "about:blank",
                                browserRenderer: "frontend", browserEngine: coldBrowser ? "cef" : "webkit"),
                    third]
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: tabs)
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"unloaded-tab-keeps-pane-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// Waits until the main run loop's pass has committed (a one-shot before-waiting observer after every other one).
    private static func nextCommittedPass() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                              false, CFIndex.max) { _, _ in
                done.resume()
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
        }
    }

    /// The pane the moved tab goes to: it takes the tab's view from the source pane (`TabContentCache.present`).
    private final class TakingPane: SurfacePresenter {
        func surfaceWasDisplaced(_ key: String) {}
        func surfaceIsFree(_ key: String) {}
    }

    /// A pane in a window showing the History page (tab 1), with a never-shown browser (tab 2) and terminal (tab 3).
    @MainActor private struct Fixture {
        let services: AppServices
        let pane: PaneController
        let state: WindowState
        let window: NSWindow
        let history: String, blank: String, terminal: String
        let page: HistoryPageTab

        init(coldBrowser: Bool = false, agentTab: Bool = false) async throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            let store = services.daemon.store
            store.connectionState = .connected(try UnloadedTabKeepsPaneTests.connected())
            store.apply(snapshot: UnloadedTabKeepsPaneTests.tree(coldBrowser: coldBrowser, agentTab: agentTab))
            if coldBrowser {
                services.cache.browserTabs.cefUnavailable = { nil }
                services.cache.browserTabs.opened(BrowserEngineChoice(engine: .cef), SurfaceID(rawValue: 2), on: services.daemon)
            }
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            history = try #require(store.tab(surface: SurfaceID(rawValue: 1))).id
            blank = try #require(store.tab(surface: SurfaceID(rawValue: 2))).id
            terminal = try #require(store.tab(surface: SurfaceID(rawValue: 3))).id
            page = HistoryPageTab(id: BrowserTabID(rawValue: history), engine: .webkit, profile: .default, webPage: nil)
            _ = services.cache.install(page, for: history)
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
            state = WindowState(record: record)
            pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services, state: state)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            pane.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
            window.contentView = pane.view
            window.orderFrontRegardless()
            pane.setPresence(.visible)
            state.selection.select(history, in: pane.paneKey)
            pane.syncStripFromStore()
            pane.view.layoutSubtreeIfNeeded()
            for _ in 0..<12 where pane.currentTabKey != history || page.contentView.window == nil { await UnloadedTabKeepsPaneTests.nextCommittedPass() }
            try #require(pane.currentTabKey == history && pane.view.hostsContent, "the History page never showed")
            try #require(services.cache.existingBrowser(blank) == nil && services.cache.existingTerminal(terminal) == nil,
                         "fixture: tabs 2 and 3 were shown before")
        }

        func close() {
            pane.teardown()
            window.close()
            services.cache.browsers[history] = nil
            services.cache.release(blank)
        }

        /// The person selects `key` (a click goes through the same path: `applySelection` -> `presentSelection`).
        func select(_ key: String) {
            state.selection.select(key, in: pane.paneKey)
            pane.syncStripFromStore()
        }
    }

    /// A click on an unloaded tab, of each kind the pane makes on a first visit: in no committed pass between the click
    /// and the new tab's content is the pane empty. Fails before the fix: the first-visit path emptied the pane in the
    /// click's own pass (`letGo(parks: true)`).
    @Test(arguments: ["browser", "terminal"])
    func aClickOnAnUnloadedTabNeverEmptiesThePane(kind: String) async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let target = kind == "browser" ? fixture.blank : fixture.terminal
        fixture.select(target)
        try #require(fixture.pane.stripModel.selectedID?.rawValue == target, "the strip did not select the unloaded tab")
        var emptyPasses = fixture.pane.view.hostsContent ? 0 : 1
        for _ in 0..<12 where fixture.pane.currentTabKey != target {
            await Self.nextCommittedPass()
            if !fixture.pane.view.hostsContent { emptyPasses += 1 }
        }
        #expect(emptyPasses == 0, "the pane showed nothing for \(emptyPasses) committed pass(es) between the click and the \(kind) tab")
        #expect(fixture.pane.currentTabKey == target, "the unloaded \(kind) tab never showed")
        #expect(fixture.pane.view.hostsContent, "matching the selected key does not prove its content exists")
    }

    /// Holds actual asynchronous page creation, rather than stopping observation as soon as the selected key matches.
    @MainActor private final class PageArrival {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        var started = false
        func wait() async {
            started = true
            if !released { await withCheckedContinuation { continuation = $0 } }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    private static func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "page creation did not reach the expected state")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func anIncomingAgentCoverSurvivesRetiringTheOutgoingCover() async throws {
        let fixture = try await Fixture(agentTab: true)
        defer { fixture.close() }
        let directory = FileManager.default.temporaryDirectory.appending(path: "cold-agent-cover-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html><body>Agent</body></html>".utf8).write(to: file)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        let tabs = fixture.services.agentTabs
        let tabKey = tabs.tabKey(fixture.terminal, machine: fixture.services.daemon.machineID)
        tabs.views[tabKey] = view
        defer { tabs.views[tabKey] = nil; view.close() }
        let bitmap = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let frame = try #require(bitmap.makeImage())
        let images = tabs.launchImages
        try #require(await images.hold(images.slot(fixture.terminal, machine: fixture.services.daemon.machineID), frame,
                                       size: fixture.pane.view.contentHost.bounds.size, appearance: nil))
        fixture.pane.view.showLaunchImage(NSImage(cgImage: frame, size: fixture.pane.view.contentHost.bounds.size))
        let outgoingCover = try #require(fixture.pane.view.launchImageView)
        fixture.select(fixture.terminal)
        fixture.pane.showSelected()
        #expect(fixture.pane.currentTabKey == fixture.terminal)
        let incomingCover = try #require(fixture.pane.view.launchImageView, "resolving the page must not install a cover that the subsequent clear erases")
        #expect(incomingCover !== outgoingCover, "the previous tab's cover must be retired")
    }

    @Test(arguments: ["ready", "switchAway", "clearSelection", "initiallyEmpty"])
    func aDelayedPageKeepsTheOutgoingContentUntilItArrives(outcome: String) async throws {
        let fixture = try await Fixture(coldBrowser: true)
        let arrival = PageArrival()
        defer { arrival.release(); fixture.close() }
        var ready = false
        fixture.services.cache.makeCEFTab = { configuration in
            await arrival.wait()
            return MockBrowserEngine(kind: .cef, completesNavigationsImmediately: false).makeMockTab(configuration)
        }
        // This standalone pane is not in WindowRegistry. Use the same selected-aware callback as AppServices.
        fixture.services.cache.onBrowserReady = { [weak pane = fixture.pane] key in
            ready = true
            _ = pane?.showsAgain(key)
        }
        if outcome == "initiallyEmpty" {
            fixture.pane.stripModel.selectedID = nil
            fixture.pane.showSelected()
            try #require(!fixture.pane.view.hostsContent)
        }
        fixture.select(fixture.blank)
        try await Self.until { arrival.started }
        for _ in 0..<6 {
            await Self.nextCommittedPass()
            #expect(fixture.services.cache.existingBrowser(fixture.blank) == nil, "creation remains held")
            if outcome != "initiallyEmpty" {
                #expect(fixture.pane.currentTabKey == fixture.history)
                #expect(fixture.pane.view.hostsContent && fixture.page.contentView.window === fixture.window)
                #expect(fixture.services.cache.isRendering(fixture.history), "an attached but withdrawn Chromium page would still blank")
            }
        }
        if outcome == "switchAway" { fixture.select(fixture.history) }
        if outcome == "clearSelection" {
            fixture.pane.stripModel.selectedID = nil
            fixture.pane.showSelected()
            #expect(fixture.pane.currentTabKey == nil && !fixture.pane.view.hostsContent)
            #expect(!fixture.services.cache.isRendering(fixture.history))
        }
        arrival.release()
        try await Self.until { ready }
        for _ in 0..<6 { await Self.nextCommittedPass() }
        switch outcome {
        case "switchAway":
            #expect(fixture.pane.currentTabKey == fixture.history && fixture.pane.view.hostsContent)
            #expect(fixture.services.cache.isRendering(fixture.history))
        case "clearSelection":
            #expect(fixture.pane.currentTabKey == nil && !fixture.pane.view.hostsContent, "a late completion must not restore a cleared selection")
        default:
            #expect(fixture.pane.currentTabKey == fixture.blank && fixture.pane.view.hostsContent)
            #expect(fixture.services.cache.isRendering(fixture.blank))
            #expect(!fixture.services.cache.isRendering(fixture.history))
        }
    }

    /// The source pane of a tab move, when the move's view leaves before the pane learns its new selection: the
    /// neighbor it then selects, never shown, shows in that same pass. Fails before the fix: the pane stayed empty until
    /// the next display frame.
    @Test func aMoveThatLeavesThePaneEmptyShowsTheNeighborInTheSamePass() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let taker = TakingPane()
        fixture.services.cache.present(fixture.history, by: taker, presence: .visible) // the other pane takes the view
        try #require(!fixture.pane.view.hostsContent, "the move did not take the History page's view")
        fixture.select(fixture.blank)
        #expect(fixture.pane.currentTabKey == fixture.blank && fixture.pane.view.hostsContent,
                "the source pane stayed empty after the move (shows \(fixture.pane.currentTabKey ?? "nothing"))")
    }

    /// The other order: the source pane selects the never-shown neighbor first (it keeps the moving tab drawn), then the
    /// destination takes the view. The neighbor shows before the pass commits, never a frame later.
    @Test func aMoveAfterTheNeighborIsSelectedShowsItBeforeTheCommit() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        fixture.select(fixture.blank)
        try #require(fixture.pane.view.hostsContent, "the pane emptied when it selected the unloaded neighbor")
        let taker = TakingPane()
        fixture.services.cache.present(fixture.history, by: taker, presence: .visible)
        await Self.nextCommittedPass()
        #expect(fixture.pane.currentTabKey == fixture.blank && fixture.pane.view.hostsContent,
                "the source pane was empty at the commit after the move (shows \(fixture.pane.currentTabKey ?? "nothing"))")
    }
}
