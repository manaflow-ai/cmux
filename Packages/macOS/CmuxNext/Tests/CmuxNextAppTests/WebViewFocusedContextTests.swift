import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFocus
import Foundation
import Testing
import WebKit

/// BROWSER VIDEO (2026-11-02, films of feat ad8ae1b on cmux19 and cmux21): with a browser page focused (a real click on
/// it), `action.run devtools.openDocked` was refused "not available in the current context" in 9 of 18 rounds. The
/// Developer Tools set requires `webViewFocused`, and that bit was computed only when the focus machine's derived
/// context (terminal, browser, agent) changed. A page's content shown after its pane took the focus
/// (`contentPresented`), or a focus move between two panes of the same kind, left the bit as it was: the registry
/// kept the context of a pane that had no web view yet. The bits the App derives from the focused surface (web view,
/// address bar, page kind) are now published again whenever the focus target or its content changes.
@MainActor @Suite(.serialized)
struct WebViewFocusedContextTests {
    /// The focused pane's content comes after the focus (a new browser workspace: the page is created after the pane
    /// is focused); `contentPresented` must publish the web view's bit.
    @Test func contentShownAfterTheFocusPublishesWebViewFocused() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        rig.controller.focus.send(.focusPane(rig.second.paneKey, source: .programmatic))
        #expect(!rig.services.registry.context.contains(.webViewFocused), "no web view in the pane yet")
        rig.addWebView(to: rig.second)
        rig.controller.focus.send(.contentPresented(pane: rig.second.paneKey))
        #expect(rig.services.registry.context.contains(.webViewFocused), "the shown content has a web view")
    }

    /// A focus move between two panes of the same kind (no change of the terminal/browser/agent bits) publishes the
    /// web view bit of the pane that now has the focus, both ways.
    @Test func aFocusMoveBetweenPanesOfTheSameKindFollowsTheWebView() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        rig.addWebView(to: rig.second)
        rig.controller.focus.send(.focusPane(rig.first.paneKey, source: .programmatic))
        rig.services.registry.context.remove(.webViewFocused)
        rig.controller.focus.send(.focusPane(rig.second.paneKey, source: .programmatic))
        #expect(rig.services.registry.context.contains(.webViewFocused), "the focused pane shows a web view")
        rig.controller.focus.send(.focusPane(rig.first.paneKey, source: .programmatic))
        #expect(!rig.services.registry.context.contains(.webViewFocused), "the focused pane has no web view")
    }

    /// Two panes side by side, one terminal tab each.
    private static func tree() -> DaemonTree {
        let first = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let second = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~")])
        let layout: LayoutNode = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(first.id), b: .leaf(second.id))
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: [first, second])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "webview-context-ws"), name: "web view context", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "webview-context-ws"), index: 0)])
        return tree
    }

    /// One window on `tree()` (as `AgentChatTargetAppTests.Rig`).
    @MainActor final class Rig {
        let services: AppServices
        let controller: WindowController
        let first: PaneController
        let second: PaneController
        private var webViews: [WKWebView] = []

        init() async throws {
            _ = NSApplication.shared
            let services = AppServices(environment: AppEnvironment.current([:]))
            AppActions.bind(services)
            services.windows.ordersWindowsIn = false
            let store = services.machines.local.store
            let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
            store.noteHandshake(identity)
            store.connectionState = .connected(identity)
            store.apply(snapshot: WebViewFocusedContextTests.tree())
            let controller = try #require(services.windows.openWindow(workspaces: ["webview-context-ws"], frame: CGRect(x: 200, y: 200, width: 1200, height: 760)))
            self.services = services
            self.controller = controller
            for _ in 0..<200 where controller.workspaceContent?.panes.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
            let content = try #require(controller.workspaceContent)
            try #require(content.panes.count == 2, "the window never showed the workspace's two panes")
            content.contentView.layoutSubtreeIfNeeded()
            let models = try #require(store.workspaces.first { $0.key == WorkspaceKey(rawValue: "webview-context-ws") }?.screens.first?.panes)
            try #require(models.count == 2)
            first = try #require(content.paneController(key: models[0].id))
            second = try #require(content.paneController(key: models[1].id))
            try #require(services.windows.active === controller)
        }

        /// A shown web view inside `pane`'s view (what a browser or agent page brings when its content is shown).
        func addWebView(to pane: PaneController) {
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
            pane.view.addSubview(webView)
            webViews.append(webView)
        }

        func tearDown() {
            webViews.forEach { $0.removeFromSuperview() }
            controller.teardown()
            controller.window?.close()
        }
    }
}
