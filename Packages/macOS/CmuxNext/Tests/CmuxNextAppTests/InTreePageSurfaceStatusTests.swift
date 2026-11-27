import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// `debug.surfaces` and the blank-pane invariant said every in-tree page was hidden and its pane blank, painting or not:
/// `CEFTab.contentVisibility` looked for the page's own child window, which an in-tree page (fork API 36) does not have.
/// Every browser pane read `blank: true`, `blank_reason: page_hidden`, `content_visible: false`, `content_reason:
/// page_window_missing` and counted in `blank_panes`, and `SurfaceInvariantMonitor` logged a `blank pane` fault for it on
/// every pane change (views-window design note; other-Mac run vw4a-diag-ctl-r1: blank_panes 4 while all four pages
/// painted). The pane here is the app's own pane controller, in a real window, showing a Chromium tab the app's cache
/// holds; the fork's side (the page put into cmux's container) is a stand-in, as no Chromium runs in a test process.
@Suite(.serialized, .closesItsWindows)
@MainActor struct InTreePageSurfaceStatusTests {
    /// Tabs hold their runtime unowned and may outlive a test's locals: every runtime lives on.
    private static var runtimes: [CEFRuntime] = []
    private static let browser: Int32 = 31

    private static func tree() -> DaemonTree {
        let tabs = [TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .browser, url: "http://127.0.0.1:8765/osr.html?n=visible",
                                browserRenderer: "frontend", browserEngine: "cef")]
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: tabs)
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"in-tree-page-surface-status-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// A shim whose `cmux_shim_create_window` reports the browser started; every other function does nothing.
    private static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            name == "cmux_shim_create_window" ? unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self) : unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
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

    /// The fork's side of the page: its WebContentsViewCocoa, which the fork puts in cmux's container as its bottom
    /// subview, and the main frame's RenderWidgetHostViewCocoa inside it once a navigation made one.
    final class StandInPage {
        let contents = NSView()
        private(set) var widget: NSView?

        var calls: CEFInTreeCalls {
            CEFInTreeCalls(setInTreeHosting: { [self] _, container in
                guard let container else {
                    contents.removeFromSuperview()
                    return nil
                }
                contents.frame = container.bounds
                container.addSubview(contents, positioned: .below, relativeTo: nil)
                return contents
            }, contentView: { [self] _ in widget })
        }

        /// The first navigation makes the main frame's view; the page paints from here on.
        func navigationMakesItsView() {
            let view = NSView(frame: contents.bounds)
            contents.addSubview(view)
            widget = view
        }
    }

    /// The pane's surface status as `debug.surfaces` reports it.
    private static func report(_ status: PaneSurfaceStatus) throws -> [String: CmuxNextSettings.JSONValue] {
        try #require(status.json.objectValue)
    }

    /// In-tree pages on; the app's pane controller in a window shows the workspace's Chromium tab, whose browser Chromium
    /// made, and the fork put the page into the pane host's in-tree container, where its first navigation made its view.
    private static func withPaintingInTreePage(_ body: (PaneController, CEFTab, StandInPage) async throws -> Void) async throws {
        InTreePages.shared.setForTesting(requested: true, engine: .supported)
        defer { InTreePages.shared.setForTesting(requested: nil) }
        // The window is never on screen in a test process (another window may cover it): its content may draw anyway,
        // as in an automation launch, so the pane is judged.
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }

        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try connected())
        store.apply(snapshot: tree())
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let webTab = try #require(store.tab(surface: SurfaceID(rawValue: 1)))

        let root = FileManager.default.temporaryDirectory.appending(path: "in-tree-surface-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = CEFRuntime(shim: try library(), storage: CEFProfileStorage(root: root))
        runtimes.append(runtime)
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: "\(CEFPaneHost.ownTabPrefix)\(UUID().uuidString)"), profile: .default),
                               runtime: runtime)
        let tab = CEFTab(id: BrowserTabID(rawValue: webTab.id), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        let request = try #require(runtime.pendingWindows.first { $0.value === host }?.key)
        runtime.handle(.afterCreated(browser: browser, request: request, window: 1))
        try #require(tab.browserID == browser)
        _ = services.cache.install(tab, for: webTab.id)
        defer { services.cache.browsers[webTab.id] = nil }

        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services, state: state)
        defer { pane.teardown() }
        // Far from every other test's window: a window over the pane would count as a foreign page.
        let window = NSWindow(contentRect: NSRect(x: -24_000, y: -18_000, width: 900, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        pane.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        window.contentView = pane.view
        window.orderFrontRegardless()
        pane.setPresence(.visible) // the layout reports the pane on screen
        state.selection.select(webTab.id, in: pane.paneKey)
        pane.syncStripFromStore()
        pane.view.layoutSubtreeIfNeeded()
        for _ in 0..<12 where pane.currentTabKey != webTab.id || tab.contentView.window == nil { await nextCommittedPass() }
        try #require(pane.currentTabKey == webTab.id && tab.contentView.window === window, "the Chromium tab never showed in its pane")
        // The pane laid out its content: the host view has the page area the in-tree container takes when the page comes in.
        pane.view.layoutSubtreeIfNeeded()
        let area = tab.host.hostView.bounds
        try #require(area.width >= 1 && area.height >= 1, "the page's host view has no room in the pane: \(area)")

        // The fork puts the page in the tree; its request runs at the end of the turn.
        let page = StandInPage()
        try #require(tab.host.hostView.inTree.pageWindowCreated(browser: browser, calls: page.calls))
        await nextCommittedPass()
        try #require(tab.host.hostView.inTree.isInTree && page.contents.window === window,
                     "the stand-in page is not in the pane's window: the test proves nothing")
        try #require(tab.presentation == .inTree && tab.isShown, "the page does not show in tree")
        page.navigationMakesItsView()
        try await body(pane, tab, page)
    }

    /// A painting in-tree page: its pane is not blank in `debug.surfaces`, and the invariant counts and logs no blank pane.
    @Test func aPaintingInTreePageIsNoBlankPane() async throws {
        try await Self.withPaintingInTreePage { pane, _, _ in
            let status = pane.surfaceStatus
            let report = try Self.report(status)
            #expect(report["content_visible"] == .bool(true), "a painting in-tree page reads hidden: \(report["content_reason"] ?? .null)")
            #expect(report["blank_reason"] == .null, "the pane reads blank: \(report["blank_reason"] ?? .null)")
            #expect(report["blank"] == .bool(false))
            #expect(report["content_reason"] == nil)
            #expect(report["foreign_pages"] == CmuxNextSettings.JSONValue(0), "another window covers the test's pane")

            let invariant = SurfaceInvariantMonitor()
            invariant.judge([status])
            #expect(invariant.violations == 0, "the invariant logged a blank-pane fault for a painting in-tree page")
        }
    }

    /// The invariant still catches a pane whose in-tree page is gone from it: the page left the tree while the pane shows
    /// its tab.
    @Test func aPaneWhoseInTreePageLeftTheTreeIsStillBlank() async throws {
        try await Self.withPaintingInTreePage { pane, tab, page in
            tab.host.hostView.inTree.stop()
            try #require(page.contents.window == nil)
            let status = pane.surfaceStatus
            let report = try Self.report(status)
            #expect(report["content_visible"] == .bool(false), "a page out of the tree reads visible")
            #expect(report["blank_reason"] == .string("page_hidden"))
            let invariant = SurfaceInvariantMonitor()
            invariant.judge([status])
            #expect(invariant.violations == 1, "the invariant missed a pane with no page")
        }
    }
}
