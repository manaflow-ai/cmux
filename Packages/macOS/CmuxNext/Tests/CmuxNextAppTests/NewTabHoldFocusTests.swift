import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFocus
import Foundation
import Testing

/// Keys typed right after a New Tab page opens wait in the window's key hold
/// (`NewTabInputCoordinator`) and go to the page's field when it reports ready. The hold gives the
/// field the keyboard with `makeFirstResponder`, and the window refuses an agent page's web view
/// outside an input event and the focus model's own moves while the model names another pane
/// (`AgentPaneView.refusesSelfFocus`). A page opened cold in a pane the focus model had not reached
/// (the + of a pane other than the focused one; no prewarmed spare, so nothing sent `focusPane`)
/// therefore never drained: its keys waited for the hold's 2 s limit and then went to the pane that
/// still had focus.
@MainActor @Suite(.serialized)
struct NewTabHoldFocusTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// One workspace, two panes side by side, each with one tab.
    private static func tree() -> DaemonTree {
        let first = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let second = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~")])
        let layout: LayoutNode = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(first.id), b: .leaf(second.id))
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: [first, second])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "hold-ws"), name: "hold", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "hold-ws"), index: 0)])
        return tree
    }

    private static func key(_ character: String, keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, characters: character,
                                      charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode))
    }

    @Test func keysHeldForAPageInAPaneFocusHasNotReachedGoToItsFieldAtItsReadiness() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["hold-ws"], frame: CGRect(x: 200, y: 200, width: 1200, height: 760)))
        let directory = FileManager.default.temporaryDirectory.appending(path: "new-tab-hold-\(UUID().uuidString)")
        var pageKey: String?
        defer {
            if let pageKey {
                services.agentTabs.views[pageKey] = nil
                services.agentTabs.newTabPages[pageKey] = nil
            }
            controller.teardown()
            controller.window?.close()
            try? FileManager.default.removeItem(at: directory)
        }
        for _ in 0..<200 where controller.workspaceContent?.panes.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        let content = try #require(controller.workspaceContent)
        try #require(content.panes.count == 2, "the window never showed the workspace's two panes")
        content.contentView.layoutSubtreeIfNeeded()
        let window = try #require(controller.window)
        let models = try #require(store.workspaces.first?.screens.first?.panes)
        try #require(models.count == 2)
        let focused = try #require(content.paneController(key: models[0].id))
        let other = try #require(content.paneController(key: models[1].id))
        for _ in 0..<100 where other.currentTabKey == nil { try await Task.sleep(for: .milliseconds(10)) }
        if other.currentTabKey == nil { other.showSelected() }
        let key = try #require(other.currentTabKey, "the second pane shows no tab")
        pageKey = key

        // The second pane's tab is a New Tab page whose field has not reported ready yet.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "index.html")
        try Data("<html><body><input></body></html>".utf8).write(to: file)
        let model = AgentPaneModel(host: NoHost(), allowsTabConversion: true)
        model.becomeNewTab(AgentPaneNewTab(kind: .agent))
        let page = try #require(AgentPaneView(model: model, source: .bundled(file)))
        page.frame = other.view.bounds
        other.view.addSubview(page)
        services.agentTabs.views[key] = page
        services.agentTabs.newTabPages[key] = (AgentPaneNewTab(kind: .agent),
                                               NewTabPageHandler(open: { _, _ in }, jump: { _, _ in }, editShortcut: { _ in }))
        try #require(page.window === window && !page.isHiddenOrHasHiddenAncestor, "the page is not shown in the window")

        // The focus model still names the first pane.
        controller.focus.send(.focusPane(focused.paneKey, source: .programmatic))
        try #require(controller.focus.state.pane == focused.paneKey, "the first pane does not have focus")

        // The opening's hold, as NewTabPage.open begins it: only the field's readiness may end it here.
        let router = services.keyRouter
        let input = router.newTabInputCoordinator
        input.holdLimit = .seconds(600)
        input.scheduleDeadline = { _, _ in Task {} }
        let token = try #require(input.begin(for: other))
        input.didShow(in: window)
        let typed = [try Self.key("h", keyCode: 4, in: window), try Self.key("i", keyCode: 34, in: window)]
        for event in typed { #expect(router.interceptKeyDown(event, in: window), "the hold did not take \(event.characters ?? "")") }
        #expect(input.isHolding(in: window))

        // The field reports ready: the held keys go to it now, not at the hold's limit.
        input.acknowledge(token, in: window)
        #expect(!input.isHolding(in: window), "the hold kept the keys after the page's field was ready: \(input.log)")
        #expect(window.firstResponder === page.webView, "the page's field never got the keyboard (first responder \(String(describing: window.firstResponder)))")
        #expect(input.log.contains { $0.hasPrefix("drained to field") }, "the held keys did not go to the page's field: \(input.log)")
        #expect(controller.focus.state.pane == other.paneKey, "the focus model still names the pane the keys were not typed for")
    }
}
