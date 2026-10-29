import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFocus
import CmuxNextFocusUI
import CmuxNextWakeups
import Foundation
import Testing

/// A New Tab page that never reports its field ready (its load failed, it crashed past its reload budget, or its tab
/// went) ends the key hold of the opening that made it (`NewTabInputCoordinator.pageFailed`): the keys typed for that
/// field drop with a reason, none runs into another view, and the keyboard is the person's again. Before, nothing but
/// the person's Escape ended such a hold: no timer may, and the page sent no failure.
@MainActor @Suite(.serialized)
struct NewTabPageFailureTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// One workspace, two panes side by side, each with one tab (as `NewTabHoldFocusTests`).
    private static func tree() -> DaemonTree {
        let first = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let second = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~")])
        let layout: LayoutNode = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(first.id), b: .leaf(second.id))
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: [first, second])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "fail-ws"), name: "fail", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "fail-ws"), index: 0)])
        return tree
    }

    private static func key(_ character: String, keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, characters: character,
                                      charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode))
    }

    private struct Harness {
        let services: AppServices
        let window: NSWindow
        let pane: PaneController
        let key: String
        let page: AgentPaneView
        let token: String
    }

    /// A window whose second pane shows a New Tab page, wired as the app wires every agent tab's page
    /// (`AgentTabStore.wire`), that an opening's hold (Cmd-T's, `begin(for:)`) waits for. Two keys were typed for its
    /// field, which has not reported ready. `body` runs with it.
    private static func withHeldKeysForAPage(_ body: (Harness) async throws -> Void) async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["fail-ws"], frame: CGRect(x: 200, y: 200, width: 1200, height: 760)))
        var pageKey: String?
        defer {
            if let pageKey {
                services.agentTabs.views[pageKey] = nil
                services.agentTabs.newTabPages[pageKey] = nil
            }
            controller.teardown()
            controller.window?.close()
        }
        for _ in 0..<200 where controller.workspaceContent?.panes.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        let content = try #require(controller.workspaceContent)
        try #require(content.panes.count == 2, "the window never showed the workspace's two panes")
        content.contentView.layoutSubtreeIfNeeded()
        let window = try #require(controller.window)
        let models = try #require(store.workspaces.first?.screens.first?.panes)
        try #require(models.count == 2)
        let pane = try #require(content.paneController(key: models[1].id))
        for _ in 0..<100 where pane.currentTabKey == nil { try await Task.sleep(for: .milliseconds(10)) }
        if pane.currentTabKey == nil { pane.showSelected() }
        let key = try #require(pane.currentTabKey, "the second pane shows no tab")
        pageKey = key

        // The pane's tab is a New Tab page, wired as the app wires it.
        let file = try #require(AgentPageAppTestRoot.page)
        let model = AgentPaneModel(host: NoHost(), allowsTabConversion: true)
        model.becomeNewTab(AgentPaneNewTab(kind: .agent))
        let page = try #require(AgentPaneView(mainThread: .standalone(), model: model, work: BackgroundWork(label: "test.agent-pane"), source: .bundled(file), webUI: .agentTabsTestHost(), gestures: .testing()))
        page.frame = pane.view.bounds
        pane.view.addSubview(page)
        services.agentTabs.views[key] = page
        services.agentTabs.wire(model, key: key)
        try #require(page.window === window && !page.isHiddenOrHasHiddenAncestor, "the page is not shown in the window")

        // The opening's hold, as `NewTabPage.open` begins it; the page carries its token, as the opening's page does.
        let input = services.keyRouter.newTabInputCoordinator
        let token = try #require(input.begin(for: pane))
        input.didShow(in: window)
        var newTab = AgentPaneNewTab(kind: .agent)
        newTab.inputToken = token
        model.becomeNewTab(newTab)
        services.agentTabs.newTabPages[key] = (newTab, NewTabPageHandler(open: { _, _ in }, jump: { _, _, _ in }, editShortcut: { _ in }))
        for event in [try Self.key("h", keyCode: 4, in: window), try Self.key("i", keyCode: 34, in: window)] {
            try #require(services.keyRouter.interceptKeyDown(event, in: window), "the hold did not take \(event.characters ?? "")")
        }
        try #require(input.isHolding(in: window))

        try await body(Harness(services: services, window: window, pane: pane, key: key, page: page, token: token))
    }

    /// The hold ended in the failure's turn, its two keys dropped, none ran into a view, and Escape is the person's
    /// again (not held).
    private static func expectHoldEndedAndKeysDropped(_ h: Harness, droppedBefore: Int, ranBefore: Int, _ cause: String) throws {
        let router = h.services.keyRouter
        let input = router.newTabInputCoordinator
        #expect(!input.isHolding(in: h.window), "the hold kept waiting for the field of a page that \(cause): \(input.log)")
        let dropped = router.inputQueues.existing(for: h.window.windowNumber)?.counts.dropped ?? 0
        #expect(dropped == droppedBefore + 2, "the keys typed for the page that \(cause) did not drop (dropped \(dropped)): \(input.log)")
        #expect(h.services.inputLatency.heldKeys.stage(.newTab).count == ranBefore, "a key typed for the page that \(cause) ran into another view")
        let escape = try Self.key("\u{1b}", keyCode: 53, in: h.window)
        #expect(!router.interceptKeyDown(escape, in: h.window), "Escape was held after the page \(cause): \(input.log)")
        #expect(router.inputQueues.existing(for: h.window.windowNumber)?.problems ?? [] == [], "the window's held-key invariant broke")
    }

    @Test func aPageThatCrashedPastItsReloadBudgetEndsTheHoldAndDropsItsKeys() async throws {
        try await Self.withHeldKeysForAPage { h in
            let queue = h.services.keyRouter.inputQueues.existing(for: h.window.windowNumber)
            let droppedBefore = queue?.counts.dropped ?? 0
            let ranBefore = h.services.inputLatency.heldKeys.stage(.newTab).count

            // The page host's report: the page crashed again and is not reloaded (its crash notice shows).
            h.page.page.onCrash?(h.page.page, false)

            try Self.expectHoldEndedAndKeysDropped(h, droppedBefore: droppedBefore, ranBefore: ranBefore, "crashed")
        }
    }

    @Test func aPageWhoseTabWentBeforeItsFieldWasReadyEndsTheHoldAndDropsItsKeys() async throws {
        try await Self.withHeldKeysForAPage { h in
            let queue = h.services.keyRouter.inputQueues.existing(for: h.window.windowNumber)
            let droppedBefore = queue?.counts.dropped ?? 0
            let ranBefore = h.services.inputLatency.heldKeys.stage(.newTab).count

            // The page's tab goes (a close, or the daemon's tree dropped it): the store lets its page go.
            h.services.agentTabs.release(h.key)

            try Self.expectHoldEndedAndKeysDropped(h, droppedBefore: droppedBefore, ranBefore: ranBefore, "closed")
        }
    }
}
