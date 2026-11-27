import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
import CmuxNextFocus
import CmuxNextTestSupport
import Foundation
import Testing

/// Cmd-F in an in-tree page that had the keyboard ran cmux's Find before the page saw the key. Find and its neighbours go
/// to a page with the keyboard first, and cmux runs Find only when the page leaves the key unhandled (Google Sheets takes
/// Cmd-F for its own search with `preventDefault`, Lawrence 2026-10-23; `KeyRouter+PageFirstKeys`). The router asks
/// whether the focused tab's page has the keyboard in the key window (`KeyRouter.pageHasKeys`), and that question looked
/// only for the page's own child window, which an in-tree page (fork API 36) does not have: its view is the cmux window's
/// first responder. So the router said no and ran Find at once. Other-Mac runs on the same build: in tree, `debug.key`
/// Cmd-F with the page's keyboard answered `handled_by: app`, `action: find`, and the page logged no keydown; in NIGHTLY's
/// child-window mode, the page window key, the page got Cmd-F first.
///
/// Here: the app's own window, key router and pane, showing a Chromium tab the app's cache holds, in tree, whose page has
/// the cmux window's keyboard. The fork's side (the page put into cmux's container, its main-frame view) is a stand-in,
/// as no Chromium runs in a test process.
@Suite(.serialized, .closesItsWindows)
@MainActor struct InTreePageFindKeyTests {
    /// Tabs hold their runtime unowned and may outlive a test's locals: every runtime lives on.
    private static var runtimes: [CEFRuntime] = []
    private static let browser: Int32 = 41

    /// A view that takes the keyboard, as Chromium's RenderWidgetHostViewCocoa does.
    final class KeyView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// The fork's side of the page: its WebContentsViewCocoa, which the fork puts in cmux's container as its bottom
    /// subview, and the main frame's RenderWidgetHostViewCocoa inside it once a navigation made one.
    final class StandInPage {
        let contents = KeyView()
        private(set) var widget: KeyView?

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

        /// The first navigation makes the main frame's view.
        func navigationMakesItsView() -> KeyView {
            let view = KeyView(frame: contents.bounds)
            contents.addSubview(view)
            widget = view
            return view
        }
    }

    /// One workspace whose screen shows `count` panes side by side, each with one Chromium browser tab (surfaces 1...count).
    private static func tree(panes count: Int) -> DaemonTree {
        let panes = (1...count).map { n in
            PaneSnapshot(id: PaneID(rawValue: UInt64(n)), tabs: [TabSnapshot(surface: SurfaceID(rawValue: UInt64(n)), kind: .browser,
                                                                              url: "http://127.0.0.1:8765/osr.html?n=\(n)",
                                                                              browserRenderer: "frontend", browserEngine: "cef")])
        }
        let node = count == 1 ? LayoutNode.leaf(panes[0].id)
            : panes.dropLast().reversed().reduce(LayoutNode.leaf(panes[count - 1].id)) { rest, pane in
                .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(pane.id), b: rest)
            }
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: node, panes: panes)
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "in-tree-find"), name: "find", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "in-tree-find"), index: 0),
        ])
        return tree
    }

    /// A shim whose `cmux_shim_create_window` reports the browser started; every other function does nothing.
    private static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            name == "cmux_shim_create_window" ? unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self) : unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }

    private static func cmdF(in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 9_001,
                                      windowNumber: window.windowNumber, context: nil, characters: "f",
                                      charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
    }

    /// One pane's Chromium tab in tree: the tab the app's cache holds, the pane showing it, and the fork's stand-in page.
    struct ShownPage {
        let tab: CEFTab
        let pane: PaneController
        let page: StandInPage
        let widget: KeyView
        let container: CEFInTreePageView
    }

    /// In-tree pages on; the app's own window shows a workspace of `count` panes, each showing a Chromium tab the app's
    /// cache holds, whose browser Chromium made and whose page the fork put into the pane host's in-tree container, where
    /// its first navigation made its view. No page has the keyboard yet.
    private static func withInTreePages(_ count: Int,
                                        _ body: (AppServices, WindowController, NSWindow, [ShownPage]) async throws -> Void) async throws {
        InTreePages.shared.setForTesting(requested: true, engine: .supported)
        defer { InTreePages.shared.setForTesting(requested: nil) }
        // The window may be covered in a test process: the pane is judged as drawn anyway, as in an automation launch.
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }

        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]), keyWindowSource: { nil }, appActiveSource: { true },
                                   heldKeyReplay: { event, _, _ in NSApp?.sendEvent(event) })
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree(panes: count))
        let workspace = try #require(store.workspaces.first)

        // The Chromium tabs the app's cache holds for the workspace's browser tabs; Chromium made each browser.
        let root = FileManager.default.temporaryDirectory.appending(path: "in-tree-find-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = CEFRuntime(shim: try Self.library(), storage: CEFProfileStorage(root: root))
        Self.runtimes.append(runtime)
        var tabs: [(key: String, tab: CEFTab)] = []
        for n in 1...count {
            let webTab = try #require(store.tab(surface: SurfaceID(rawValue: UInt64(n))))
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: "\(CEFPaneHost.ownTabPrefix)\(UUID().uuidString)"), profile: .default),
                                   runtime: runtime)
            let tab = CEFTab(id: BrowserTabID(rawValue: webTab.id), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            host.ensureCreated(tab)
            let request = try #require(runtime.pendingWindows.first { $0.value === host }?.key)
            runtime.handle(.afterCreated(browser: Self.browser + Int32(n), request: request, window: 1))
            try #require(tab.browserID == Self.browser + Int32(n))
            _ = services.cache.install(tab, for: webTab.id)
            tabs.append((webTab.id, tab))
        }
        defer { for (key, _) in tabs { services.cache.browsers[key] = nil } }

        let controller = try #require(services.windows.openWindow(workspaces: [workspace.id], frame: CGRect(x: 200, y: 200, width: 1100, height: 700)))
        let window = try #require(controller.window)
        defer {
            controller.teardown()
            window.close()
            // The panels the app made for the window (a pane chrome's popups) outlive its controller.
            AppHarnessWindows.closeThoseThisTestOpened()
        }
        window.orderFrontRegardless()
        controller.showWorkspace(requested: workspace.id)
        try await PinnedPageTests.until({ controller.content?.workspace === workspace && controller.focus.state.pane != nil },
                                        report: { "the window never showed the workspace with a pane focused" })
        var shown: [ShownPage] = []
        for (n, (key, tab)) in tabs.enumerated() {
            let pane = try #require(controller.content?.panes.values.first { $0.pane.handle == PaneID(rawValue: UInt64(n + 1)) })
            try await PinnedPageTests.until({ pane.currentTabKey == key && tab.contentView.window === window },
                                            report: { "the Chromium tab never showed in its pane: \(pane.currentTabKey ?? "-")" })
            pane.view.layoutSubtreeIfNeeded()
            // The fork puts the page in the tree (its request runs at the end of the turn); the first navigation makes its view.
            let page = StandInPage()
            try #require(tab.host.hostView.inTree.pageWindowCreated(browser: Self.browser + Int32(n + 1), calls: page.calls))
            try await PinnedPageTests.until({ tab.host.hostView.inTree.isInTree && page.contents.window === window },
                                            report: { "the stand-in page never came into the pane's window" })
            try #require(tab.presentation == .inTree, "the page does not show in tree")
            let widget = page.navigationMakesItsView()
            shown.append(ShownPage(tab: tab, pane: pane, page: page, widget: widget,
                                   container: try #require(tab.host.hostView.inTree.container)))
        }
        try await body(services, controller, window, shown)
    }

    /// An in-tree page with the cmux window's keyboard gets Cmd-F first: the router holds Find for it, and runs Find when
    /// the page reports the key unhandled.
    @Test func cmdFInAnInTreePageWithTheKeyboardGoesToThePageFirst() async throws {
        try await Self.withInTreePages(1) { services, controller, window, pages in
            let shown = pages[0]
            // cmux's grant: the page's view becomes the cmux window's first responder inside it, as CEFTab.grantFocus does
            // in tree (the window's in-tree gate lets the move through).
            let took = InTreePageFocus.shared.granting(shown.container) { window.makeFirstResponder(shown.widget) }
            try #require(took && window.firstResponder === shown.widget, "the page never took the keyboard: the test proves nothing")
            try await PinnedPageTests.until({
                if case .browserPage = controller.focus.currentState().resolved { return true }
                return false
            }, report: { "the focus model names \(controller.focus.state.resolved), not the page" })

            let router = services.keyRouter
            let facts = router.facts(in: window, controller: controller)
            #expect(facts.pageReportsUnhandledKeys, "the router reads an in-tree page with the keyboard as one no key reaches")
            let event = try Self.cmdF(in: window)
            let ranAtOnce = router.dispatch(event, in: window, controller: controller, facts: facts)
            #expect(!ranAtOnce, "cmux ran Find before the page saw Cmd-F")
            // The page leaves the key unhandled (no preventDefault): Chromium reports it, and only then does cmux's Find run.
            #expect(router.runUnhandledPageKey(event, from: ObjectIdentifier(shown.tab)), "no Find was held for the page's report")
        }
    }

    /// The other routes that ask where the keyboard is (`KeyFacts.typingOutsideFocusedTerminal`: a terminal's Cmd-V, Cmd-C
    /// and Cmd-A; `KeyFacts.keyInOtherPage`: the focused page's type-ahead and Home's primary input, #25666) look for a
    /// Chromium page window, and an in-tree page has none. They guard against the focus model naming one pane while a page
    /// in another has the keys, which a page window over the cmux window could do: it took the keys without the model
    /// hearing of it. In tree the page's view is the cmux window's own first responder, and the window reports each accepted
    /// move to the focus model (`ShellWindow.makeFirstResponder` -> `reportResponder`, `FocusResponderClassifier`: the
    /// page's pane), so the model names the page's pane and neither route sees another pane's page.
    @Test func anInTreePageThatTakesTheKeyboardFromAnotherPaneIsThePaneTheFocusModelNames() async throws {
        try await Self.withInTreePages(2) { services, controller, window, pages in
            let (left, right) = (pages[0], pages[1])
            controller.focus.send(.focusPane(right.pane.paneKey, source: .keyboard))
            try await PinnedPageTests.until({ controller.focus.currentState().resolved.pane == right.pane.paneKey },
                                            report: { "the focus model never named the right pane: \(controller.focus.state.resolved)" })

            // The left pane's page takes the cmux window's keyboard (a press on it, or cmux's grant: both pass the window's
            // in-tree gate and end in makeFirstResponder).
            let took = InTreePageFocus.shared.granting(left.container) { window.makeFirstResponder(left.widget) }
            try #require(took && window.firstResponder === left.widget, "the left page never took the keyboard: the test proves nothing")
            try await PinnedPageTests.until({
                guard case .browserPage(let pane, _) = controller.focus.currentState().resolved else { return false }
                return pane == left.pane.paneKey
            }, report: { "the focus model names \(controller.focus.state.resolved) while the left pane's page has the keys" })
            try #require(window.firstResponder === left.widget, "the keyboard left the left page: the test proves nothing")
            let router = services.keyRouter
            #expect(!router.keyInOtherPage(window, controller: controller), "the keys read as another pane's page's")
            #expect(!router.facts(in: window, controller: controller).typingOutsideFocusedTerminal)
        }
    }
}
