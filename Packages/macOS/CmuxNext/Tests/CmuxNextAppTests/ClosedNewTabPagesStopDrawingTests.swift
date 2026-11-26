import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// The count behind the liveness fix's before and after (`AgentPageLivenessTests` holds the rule itself): `closes`
/// untouched New Tab pages close and the pool keeps each in its parking for its tab's release (`keepInWindow`, as a
/// pane's close does), and no release ever comes. Counted a while after the wait's limit: how many of those pages
/// are still in the window and not hidden, which is where an engine draws a page (a WebKit view renders in any
/// window, a Chromium page was told it is visible). It reads only what the base branch has, so the same test runs
/// on both sides; it prints one `PERF-TABLESS` line per size.
@MainActor @Suite(.serialized)
struct ClosedNewTabPagesStopDrawingTests {
    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "tabless-ws"), name: "tabless", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "tabless-ws"), index: 0)])
        return tree
    }

    @Test(.timeLimit(.minutes(2)), arguments: [1, 3, 12])
    func closedNewTabPagesWhoseReleaseNeverComesStopDrawing(closes: Int) async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["tabless-ws"], frame: CGRect(x: 200, y: 200, width: 1100, height: 720)))
        let folder = FileManager.default.temporaryDirectory.appending(path: "tabless-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let html = folder.appending(path: "index.html")
        try Data("<html><body>tabless fixture</body></html>".utf8).write(to: html)
        let pool = services.newTabSpares
        var pages: [AgentPaneView] = []
        defer {
            pool.makeSpare = nil
            pool.dropAll()
            pages.forEach { $0.close() }
            controller.teardown()
            controller.window?.close()
            try? FileManager.default.removeItem(at: folder)
        }
        for _ in 0..<200 where controller.workspaceContent?.panes.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
        let content = try #require(controller.workspaceContent)
        content.contentView.layoutSubtreeIfNeeded()
        let window = try #require(controller.window)
        let pane = try #require(content.panes.values.first)
        let made: (AgentPaneNewTab) -> AgentPaneView? = { page in
            let model = AgentPaneModel(host: services.agentTabs.host, newTab: page)
            guard let view = AgentPaneView(model: model, source: .bundled(html)) else { return nil }
            model.hasHandshake = true
            model.markPainted()
            view.redraw.nextFrameOverride = { body in body() }
            pages.append(view)
            return view
        }
        pool.dropAll()
        pool.capacity = closes + 1
        pool.makeSpare = { _ in nil } // the pool's own warm makes nothing: only the closed pages are counted
        pool.retarget(window)
        try #require(pool.target === window, "fixture: the pool has no target window")

        for close in 1...closes {
            let page = try #require(made(NewTabPage.sparePage(services)), "fixture: no page")
            pane.view.install(page)
            try #require(pool.keepInWindow(page), "fixture: close \(close): the pool refused the page (\(pool.lastRecycleRefusal ?? "no reason"))")
        }
        let closed = pages
        // Past the wait's limit, with nothing else happening in the app: no keep, no warm, no release.
        try await Task.sleep(for: AgentPaneSpareReturns.limit + .milliseconds(1_500))
        let drawing = closed.filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }.count
        print("PERF-TABLESS closes=\(closes) visible_tabless=\(drawing) after=\(AgentPaneSpareReturns.limit + .milliseconds(1_500))")
        #expect(drawing == 0, "\(drawing) of \(closes) closed New Tab pages whose release never came still draw in the pool's parking, with no tab")
    }
}
