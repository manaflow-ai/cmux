import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Testing

/// CMD-T BUDGET 3 (2026-11-10), SHOULD FIX 3 of the #40696 review: a New Tab page whose tab's release comes BEFORE
/// its pane's strip update (a tab that the CLI, an agent or another device closed) still shows when the spare pool
/// takes it. The pool moves it into its parking view (`AgentPaneSpareReturns.arrived`), inside the window, so the
/// page never hears that it left sight: no `viewDidHide` (the pane's `retire` hides a page in the other order) and
/// no `viewDidMoveToWindow` with no window (the page left the window before #40696). Those two end what the page
/// has on the screen outside its own view: a menu or a tooltip the page drew past the pane's edge (`popup.show`, a
/// child panel of the window, `WebPopupHost`). A menu request is no touch (`AgentPaneBridge` answers it, not the
/// model), so the pool takes such a page.
///
/// The count: the menus of closed pages that are still on the screen after the pool took the page. The number of
/// Cmd-T + close pairs is the one argument; the answer must be 0 for every size, for a menu and for a tooltip.
@MainActor @Suite(.serialized)
struct NewTabSpareShownPageMenuTests {
    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "spare-menu-ws"), name: "spare", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "spare-menu-ws"), index: 0)])
        return tree
    }

    /// What one close left: is the closed page's menu still on the screen after the pool took the page, did the
    /// page hear that its menu ended (the window event `cmux-popup` with `dismiss`), and does the pane show the page
    /// that the next press took.
    private struct Close {
        var menuStillShown: Bool
        var pageHeardTheDismiss: Bool
        var nextPageShows: Bool
    }

    /// The `cmux-popup` dismiss events the app sent to its pages, by page.
    private final class Heard {
        var dismissals: [ObjectIdentifier: Int] = [:]
    }

    /// What the page sends for a menu (or a tooltip) that has no room in its pane (`ui/popupHost.ts`).
    private static func popup(tooltip: Bool) -> [String: Any] {
        var params: [String: Any] = [
            "items": tooltip ? [["id": "tip", "label": "A tooltip"]] : [["id": "a", "label": "First"], ["id": "b", "label": "Second"]],
            "anchor": ["left": 40, "top": 40, "right": 200, "bottom": 64], "width": 160, "instant": true,
        ]
        if tooltip { params["kind"] = "tooltip" }
        return params
    }

    /// `pairs` times: the shown, untouched New Tab page opens a menu, its tab closes, then a press takes the pool's
    /// spare and the pane shows it.
    ///
    /// `releaseFirst`: the tab's release comes before its pane's strip update, while the page shows (a tab that the
    /// CLI, an agent or another device closed: `releaseGoneTabs`); the pool moves the page out of its pane itself.
    /// Else the order of a Cmd-W: the strip update retires (hides) the page, then the release gives it to the pool.
    private static func closes(pairs: Int, tooltip: Bool, releaseFirst: Bool) async throws -> [Close] {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["spare-menu-ws"], frame: CGRect(x: 200, y: 200, width: 1100, height: 720)))
        let folder = FileManager.default.temporaryDirectory.appending(path: "spare-menu-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pool = services.newTabSpares
        var pages: [AgentPaneView] = []
        defer {
            pool.makeSpare = nil
            pool.dropAll()
            pages.forEach { $0.close() } // each page's menu ends with the page
            for panel in controller.window?.childWindows ?? [] { // a menu panel that the run left: closed, never left open
                controller.window?.removeChildWindow(panel)
                panel.isReleasedWhenClosed = false
                panel.close()
            }
            controller.teardown()
            controller.window?.close()
            try? FileManager.default.removeItem(at: folder)
        }
        for _ in 0..<200 where controller.workspaceContent?.panes.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
        let content = try #require(controller.workspaceContent)
        content.contentView.layoutSubtreeIfNeeded()
        let window = try #require(controller.window)
        let pane = try #require(content.panes.values.first)
        // A page's menu is a child panel of its window and shows only over a window that is on the screen.
        window.orderFrontRegardless()
        try #require(window.isVisible, "fixture: the window is not on the screen")

        // An inert page stands in for WebKit's (as `NewTabSpareStaysInWindowTests`): loaded and painted. The events
        // the app sends it are counted, not run.
        let html = folder.appending(path: "index.html")
        try Data("<html><body>New Tab spare menu fixture</body></html>".utf8).write(to: html)
        let heard = Heard()
        let made: (AgentPaneNewTab) -> AgentPaneView? = { page in
            let model = AgentPaneModel(host: services.agentTabs.host, newTab: page)
            guard let view = AgentPaneView(model: model, source: .bundled(html)) else { return nil }
            model.hasHandshake = true
            model.markPainted()
            view.redraw.nextFrameOverride = { body in body() }
            let id = ObjectIdentifier(view)
            view.evaluateScript = { script in
                if script.contains("cmux-popup"), script.contains("\"dismiss\"") { heard.dismissals[id, default: 0] += 1 }
            }
            return view
        }
        pool.dropAll()
        pool.capacity = 2
        pool.makeSpare = made // a timer of the pool that runs after the test makes no real page
        pool.retarget(window)
        try #require(pool.target === window, "fixture: the pool has no target window")
        try #require(pool.spares.isEmpty, "fixture: the pool holds \(pool.spares.count) spares before the run")

        // The pane shows an untouched New Tab page, as after a Cmd-T. From here on the test keeps its turn.
        let first = try #require(made(NewTabPage.sparePage(services)), "fixture: no page")
        pages.append(first)
        pane.view.install(first)
        try #require(first.window === window, "fixture: the page is not in the window")
        var shown = first
        var closes: [Close] = []
        for pair in 1...pairs {
            // The page opens a menu past its pane's edge. This is no touch: the pool still takes the page.
            let reply = shown.popup("popup.show", params: popup(tooltip: tooltip))
            let opened = (reply["value"] as? [String: Any])?["shown"] as? Bool == true
            try #require(opened, "fixture: pair \(pair): the page's menu did not show: \(reply)")
            try #require(shown.popupHostStorage?.shownFrame != nil, "fixture: pair \(pair): no menu on the screen after popup.show")
            try #require(!shown.model.userTouched, "fixture: pair \(pair): a menu touched the page (\(shown.model.touchedBy ?? "?"))")
            let heardBefore = heard.dismissals[ObjectIdentifier(shown), default: 0]

            if releaseFirst {
                try #require(pool.recycle(shown), "fixture: pair \(pair): the pool refused the shown page (\(pool.lastRecycleRefusal ?? "no reason"))")
                pane.view.dropClosedParked { [] } // the strip update, after the release
            } else {
                pane.view.retire(shown)
                pane.view.dropClosedParked { [] }
                try #require(pool.recycle(shown), "fixture: pair \(pair): the pool refused the closed page (\(pool.lastRecycleRefusal ?? "no reason"))")
            }
            try #require(pool.spares.contains { $0 === shown }, "fixture: pair \(pair): the closed page is not a spare of the pool")
            let stillShown = shown.popupHostStorage?.shownFrame != nil
            let heardNow = heard.dismissals[ObjectIdentifier(shown), default: 0] > heardBefore

            // Cmd-T: the pool hands out its oldest spare and the pane shows it.
            let taken = try #require(pool.take(for: window, size: NewTabSparePool.newTabContentSize(in: pane))?.view, "fixture: pair \(pair): the pool had no spare")
            pane.view.install(taken)
            try #require(taken.superview === pane.view.contentHost, "fixture: pair \(pair): the pane does not hold the page")
            closes.append(Close(menuStillShown: stillShown, pageHeardTheDismiss: heardNow, nextPageShows: !taken.isHiddenOrHasHiddenAncestor))
            if !pages.contains(where: { $0 === taken }) { pages.append(taken) }
            shown = taken
        }
        return closes
    }

    @Test(.enabled("needs an awake display: a page menu is a panel on the screen") { !NSScreen.screens.isEmpty },
          .timeLimit(.minutes(2)), arguments: [1, 3], [false, true])
    func noMenuOfAPageThePoolMovedOutOfItsPaneStaysOnTheScreen(pairs: Int, tooltip: Bool) async throws {
        let what = tooltip ? "tooltip" : "menu"
        let closes = try await Self.closes(pairs: pairs, tooltip: tooltip, releaseFirst: true)
        try #require(closes.count == pairs, "fixture: \(closes.count) closes, not \(pairs)")
        let left = closes.filter(\.menuStillShown).count
        print("release before strip update, \(what), \(pairs) pairs: \(left) still on the screen, \(closes.filter(\.pageHeardTheDismiss).count) pages told")
        #expect(left == 0, """
            \(left) of \(pairs) closed New Tab pages left their \(what) on the screen after the spare pool took the page: \
            the \(what) of a tab that is gone floats over the window, and the next Cmd-T shows that page
            """)
        let untold = closes.filter { !$0.pageHeardTheDismiss }.count
        #expect(untold == 0, "\(untold) of \(pairs) pages did not hear that their \(what) ended: the page still draws it as open when the next Cmd-T shows the page")
        let hidden = closes.filter { !$0.nextPageShows }.count
        #expect(hidden == 0, "\(hidden) of \(pairs) presses got a page that the pane holds hidden")
    }

    /// The other order (a Cmd-W: the pane retires the page, then the release comes) ends the menu already: the
    /// pane's `retire` hides the page. The same count through the same fixture, so the count above is not a
    /// fault of the fixture.
    @Test(.enabled("needs an awake display: a page menu is a panel on the screen") { !NSScreen.screens.isEmpty },
          .timeLimit(.minutes(2)), arguments: [1, 3])
    func aMenuOfAPageThatItsPaneRetiredFirstEnds(pairs: Int) async throws {
        let closes = try await Self.closes(pairs: pairs, tooltip: false, releaseFirst: false)
        try #require(closes.count == pairs, "fixture: \(closes.count) closes, not \(pairs)")
        #expect(closes.filter(\.menuStillShown).count == 0, "a menu of a page that its pane retired stayed on the screen")
        #expect(closes.filter { !$0.pageHeardTheDismiss }.count == 0, "a page that its pane retired did not hear that its menu ended")
        #expect(closes.filter { !$0.nextPageShows }.count == 0, "a press got a page that the pane holds hidden")
    }
}
