import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFocus
import CmuxNextWakeups
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

    private struct PageHarness {
        let services: AppServices
        let controller: WindowController
        let window: NSWindow
        let focused: PaneController
        let other: PaneController
        let page: AgentPaneView
    }

    /// A window with two panes: the second shows a New Tab page whose field has not reported ready, and the focus model
    /// names the first pane. `body` runs with it.
    private static func withUnreadyPage(_ body: (PageHarness) async throws -> Void) async throws {
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
        let focused = try #require(content.paneController(key: models[0].id))
        let other = try #require(content.paneController(key: models[1].id))
        for _ in 0..<100 where other.currentTabKey == nil { try await Task.sleep(for: .milliseconds(10)) }
        if other.currentTabKey == nil { other.showSelected() }
        let key = try #require(other.currentTabKey, "the second pane shows no tab")
        pageKey = key

        // The second pane's tab is a New Tab page whose field has not reported ready yet.
        let file = try #require(AgentPageAppTestRoot.page)
        let model = AgentPaneModel(host: NoHost(), allowsTabConversion: true)
        model.becomeNewTab(AgentPaneNewTab(kind: .agent))
        let page = try #require(AgentPaneView(mainThread: .standalone(), model: model, work: BackgroundWork(label: "test.agent-pane"), source: .bundled(file), webUI: .agentTabsTestHost(), gestures: .testing()))
        page.frame = other.view.bounds
        other.view.addSubview(page)
        services.agentTabs.views[key] = page
        services.agentTabs.newTabPages[key] = (AgentPaneNewTab(kind: .agent),
                                               NewTabPageHandler(open: { _, _ in }, jump: { _, _, _ in }, editShortcut: { _ in }))
        try #require(page.window === window && !page.isHiddenOrHasHiddenAncestor, "the page is not shown in the window")

        // The focus model still names the first pane.
        controller.focus.send(.focusPane(focused.paneKey, source: .programmatic))
        try #require(controller.focus.state.pane == focused.paneKey, "the first pane does not have focus")

        try await body(PageHarness(services: services, controller: controller, window: window, focused: focused, other: other, page: page))
    }

    @Test func keysHeldForAPageInAPaneFocusHasNotReachedGoToItsFieldAtItsReadiness() async throws {
        try await Self.withUnreadyPage { h in
            let (services, controller, window, focused, other, page) = (h.services, h.controller, h.window, h.focused, h.other, h.page)
            _ = focused
            // The opening's hold, as NewTabPage.open begins it: only the field's readiness may end it here.
            let router = services.keyRouter
            let input = router.newTabInputCoordinator
            let token = try #require(input.begin(for: other))
            input.didShow(in: window)
            let typed = [try Self.key("h", keyCode: 4, in: window), try Self.key("i", keyCode: 34, in: window)]
            for event in typed { #expect(router.interceptKeyDown(event, in: window), "the hold did not take \(event.characters ?? "")") }
            #expect(input.isHolding(in: window))

            // The field reports ready: the held keys go to it now, not at the hold's limit.
            input.acknowledge(token, in: window)
            #expect(!input.isHolding(in: window), "the hold kept the keys after the page's field was ready: \(input.log)")
            #expect(window.firstResponder === page.focusTarget, "the page's field never got the keyboard (first responder \(String(describing: window.firstResponder)))")
            #expect(input.log.contains { $0.hasPrefix("drained to field") }, "the held keys did not go to the page's field: \(input.log)")
            #expect(controller.focus.state.pane == other.paneKey, "the focus model still names the pane the keys were not typed for")
        }
    }

    /// No timer decides where a held key goes (principled audit R5, lagFirstKey step 3): the field of the page the keys
    /// were typed for is not ready when the hold's old 2 s bound passes. The keys keep waiting for that field; they never
    /// run into the view that has the keyboard instead (before, the bound gave them to whatever had focus). At the
    /// field's readiness they go to it, in order.
    @Test func keysForAPageWhoseFieldIsNotReadyNeverGoElsewhereWhenTimePasses() async throws {
        try await Self.withUnreadyPage { h in
            let (services, window, other, page) = (h.services, h.window, h.other, h.page)
            let router = services.keyRouter
            let input = router.newTabInputCoordinator
            let seam = services.inputLatency.heldKeys
            let token = try #require(input.begin(for: other))
            input.didShow(in: window)
            for event in [try Self.key("h", keyCode: 4, in: window), try Self.key("i", keyCode: 34, in: window)] {
                #expect(router.interceptKeyDown(event, in: window), "the hold did not take \(event.characters ?? "")")
            }
            let before = seam.stage(.newTab).count

            // Past the old bound (2 s after Cmd-T): no key went anywhere, and the hold still has them.
            _ = await PasswordManagerRouteTests.becomes({ seam.stage(.newTab).count != before }, within: .milliseconds(2600))
            #expect(seam.stage(.newTab).count == before, "the hold's bound sent the keys typed for the page to another view: \(input.log)")
            #expect(input.isHolding(in: window), "the hold ended without its field: \(input.log)")

            // The field reports ready: the keys go to it, in order.
            input.acknowledge(token, in: window)
            #expect(seam.stage(.newTab).count == before + 2, "the held keys did not go to the page's field: \(input.log)")
            #expect(window.firstResponder === page.focusTarget, "the page's field never got the keyboard")
            #expect(!input.isHolding(in: window))
        }
    }

    /// A dead keyboard on a New Tab page whose field never comes (review finding 6a): keys typed after Cmd-T wait for the
    /// field, and before, every chord typed after them waited too. An app command (Cmd-B, a key bound to a cmux action)
    /// acts at once and never waits behind held text. (Whether the action also ends this hold is finding 2's question:
    /// here the page opened in a pane the focus model had not reached.)
    @Test func anAppCommandNeverWaitsBehindKeysHeldForAPage() async throws {
        try await Self.withUnreadyPage { h in
            let (services, window, other) = (h.services, h.window, h.other)
            let router = services.keyRouter
            let input = router.newTabInputCoordinator
            _ = try #require(input.begin(for: other))
            input.didShow(in: window)
            #expect(router.interceptKeyDown(try Self.key("h", keyCode: 4, in: window), in: window), "the hold did not take the key")
            var ran: [ActionID] = []
            services.registry.willRunObservers.append { id, _ in ran.append(id) }
            let sidebar = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                        context: nil, characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
            _ = router.interceptKeyDown(sidebar, in: window)
            #expect(ran.contains("toggleSidebar"), "Cmd-B waited behind the keys held for the page: \(input.log)")
        }
    }

    /// The person moves the focus to another pane after Cmd-T, before typing (review finding 2): the keys they type are
    /// for that pane, not for the page. Before, the hold judged the move on the focus state before the move was reduced
    /// (the person's intent is seen before its reduction), so it kept stamping the keys for the page they left.
    @Test func aFocusMoveBeforeAnyKeyEndsThePagesHold() async throws {
        try await Self.withUnreadyPage { h in
            let (services, controller, window, focused, other) = (h.services, h.controller, h.window, h.focused, h.other)
            let router = services.keyRouter
            let input = router.newTabInputCoordinator
            controller.focus.send(.focusPane(other.paneKey, source: .programmatic))
            try await PasswordManagerRouteTests.until({ controller.focus.state.pane == other.paneKey }, within: .seconds(5),
                                                      report: { "the focus model never named the page's pane" })
            _ = try #require(input.begin(for: other))
            input.didShow(in: window)

            // The person moves to the other pane by keyboard, then types.
            controller.focus.send(.focusPane(focused.paneKey, source: .keyboard))
            let captured = router.inputQueues.existing(for: window.windowNumber)?.counts.captured ?? 0
            _ = router.interceptKeyDown(try Self.key("h", keyCode: 4, in: window), in: window)
            #expect((router.inputQueues.existing(for: window.windowNumber)?.counts.captured ?? 0) == captured,
                    "a key typed after the person moved to another pane was held for the page: \(input.log)")
            #expect(!input.isHolding(in: window), "the page's hold outlived the person's move: \(input.log)")
        }
    }
}
