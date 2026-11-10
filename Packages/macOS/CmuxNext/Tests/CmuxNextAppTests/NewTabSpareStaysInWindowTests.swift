import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// CMD-T BUDGET 2, cause (b) (2026-11-10): a Cmd-T that takes a New Tab page the pool got back from a Cmd-W paid
/// 19-23 ms in the key's turn, a first-use Cmd-T about 1 ms, for the same view insert (`PaneContentView.install`).
/// The closed page left the window in the close's turn and the pool put it back only after 750 ms with no input
/// (R81), so in a run of Cmd-T and Cmd-W the pool handed out a page that was in no window (`debug.new_tab`:
/// `window: null`), and the key's turn attached a WKWebView to the window.
///
/// The count: a run of Cmd-W + Cmd-T pairs with no quiet time between them (the test never gives up its turn, so no
/// timer of the pool runs). For each press: is the page that the pool hands out in the window, in the pool's parking
/// view. The number of pairs is the one argument; the answer must be 0 presses outside the window for every size.
@MainActor @Suite(.serialized)
struct NewTabSpareStaysInWindowTests {
    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "spare-window-ws"), name: "spare", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "spare-window-ws"), index: 0)])
        return tree
    }

    /// What one press found: the page it took, whether that page was in the window, and whether it was in the pool's
    /// parking view (a direct child of the window's content view).
    private struct Press {
        var samePage: Bool
        var inWindow: Bool
        var inParking: Bool
    }

    /// `pairs` times: the pane closes its untouched New Tab page (its strip update drops the page, then the tab's
    /// release gives the page to the pool), then a press takes the pool's spare and the pane shows it.
    private static func presses(pairs: Int) async throws -> [Press] {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["spare-window-ws"], frame: CGRect(x: 200, y: 200, width: 1100, height: 720)))
        let folder = FileManager.default.temporaryDirectory.appending(path: "spare-window-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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

        // An inert page stands in for WebKit's (as `NewTabRapidPairTests.filledPool`): loaded and painted.
        let html = folder.appending(path: "index.html")
        try Data("<html><body>New Tab spare fixture</body></html>".utf8).write(to: html)
        let made: (AgentPaneNewTab) -> AgentPaneView? = { page in
            let model = AgentPaneModel(host: services.agentTabs.host, newTab: page)
            guard let view = AgentPaneView(model: model, source: .bundled(html)) else { return nil }
            model.hasHandshake = true
            model.markPainted()
            view.redraw.nextFrameOverride = { body in body() }
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
        var presses: [Press] = []
        for pair in 1...pairs {
            // Cmd-W: the strip update retires the page and drops it as closed; then the tab's release offers it to the pool.
            pane.view.retire(shown)
            pane.view.dropClosedParked { [] }
            try #require(pool.recycle(shown), "fixture: pair \(pair): the pool refused the closed page (\(pool.lastRecycleRefusal ?? "no reason"))")
            // Cmd-T: the pool hands out its oldest spare and the pane shows it.
            let taken = try #require(pool.take(for: window, size: NewTabSparePool.newTabContentSize(in: pane))?.view, "fixture: pair \(pair): the pool had no spare")
            presses.append(Press(samePage: taken === shown, inWindow: taken.window === window,
                                 inParking: taken.superview != nil && taken.superview?.superview === window.contentView))
            pane.view.install(taken)
            try #require(taken.superview === pane.view.contentHost, "fixture: pair \(pair): the pane does not show the page")
            if !pages.contains(where: { $0 === taken }) { pages.append(taken) }
            shown = taken
        }
        return presses
    }

    @Test(.timeLimit(.minutes(2)), arguments: [1, 3, 12])
    func noRapidPressTakesAPageThatLeftTheWindow(pairs: Int) async throws {
        let presses = try await Self.presses(pairs: pairs)
        try #require(presses.count == pairs, "fixture: \(presses.count) presses, not \(pairs)")
        let report = presses.enumerated().map { "\($0.offset + 1):\($0.element.inWindow ? "window" : "null")" }.joined(separator: " ")
        print("spare per press, \(pairs) pairs: \(report)")
        let other = presses.filter { !$0.samePage }.count
        #expect(other == 0, "\(other) of \(pairs) presses did not get the page that was closed (the pool made or kept another one)")
        let outside = presses.filter { !$0.inWindow }.count
        #expect(outside == 0, """
            \(outside) of \(pairs) presses took a spare that was in no window (`window: null`): the key's turn attaches \
            a WKWebView to the window (19-23 ms) where a first-use press moves it inside the window (1 ms): \(report)
            """)
        let elsewhere = presses.filter { !$0.inParking }.count
        #expect(elsewhere == 0, "\(elsewhere) of \(pairs) presses took a spare that was not in the pool's parking view: the key's view insert depends on the spare's history")
    }
}
