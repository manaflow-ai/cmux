import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFocus
@testable import CmuxNextPages
import CmuxNextWakeups
import Foundation
import Testing

/// Keys typed right after Cmd-T, Cmd-N or Cmd-Shift-N go to the New Tab page's field as soon as the page shows with its
/// field ready, not when the page's readiness message comes. Measured on the optimized build (first-5s bench,
/// Cmd-Shift-N): the new window's page showed and had the keyboard at +42 ms, yet every key waited the 4 s
/// `incomingHoldLimit`, because the hold ended only on the page's `newTab.inputReady` and, for a page that does not
/// exist yet, it did not know the page's tab until that message came. The destination is known in the key's turn (the
/// page's tab) and its field's focus is known natively (``PageInputReadiness/isEditableFocused``).
@MainActor @Suite(.serialized)
struct NewTabFieldReadyTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// One workspace, one pane, one tab.
    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "ready-ws"), name: "ready", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "ready-ws"), index: 0)])
        return tree
    }

    private static func key(_ character: String, keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, characters: character,
                                      charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode))
    }

    private struct Fixture {
        let services: AppServices
        let controller: WindowController
        let window: NSWindow
        let pane: PaneController
        let page: AgentPaneView
        let key: String
        func close() {
            services.agentTabs.views[key] = nil
            services.agentTabs.newTabPages[key] = nil
            controller.teardown()
            controller.window?.close()
        }
    }

    /// A window whose one pane shows a New Tab page; its field reported ready (focused once), and no
    /// `newTab.inputReady` came.
    private static func fixture() async throws -> Fixture {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["ready-ws"], frame: CGRect(x: 200, y: 200, width: 1000, height: 700)))
        for _ in 0..<200 where controller.workspaceContent?.panes.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
        let content = try #require(controller.workspaceContent)
        content.contentView.layoutSubtreeIfNeeded()
        let window = try #require(controller.window)
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let pane = try #require(content.paneController(key: model.id))
        for _ in 0..<100 where pane.currentTabKey == nil { try await Task.sleep(for: .milliseconds(10)) }
        if pane.currentTabKey == nil { pane.showSelected() }
        let key = try #require(pane.currentTabKey, "the pane shows no tab")
        let file = try #require(AgentPageAppTestRoot.page)
        let agent = AgentPaneModel(host: NoHost(), allowsTabConversion: true)
        agent.becomeNewTab(AgentPaneNewTab(kind: .agent))
        let page = try #require(AgentPaneView(mainThread: .standalone(), model: agent, work: BackgroundWork(label: "test.agent-pane"),
                                              source: .bundled(file), webUI: .agentTabsTestHost(), gestures: .testing()))
        page.frame = pane.view.bounds
        pane.view.addSubview(page)
        services.agentTabs.views[key] = page
        services.agentTabs.newTabPages[key] = (AgentPaneNewTab(kind: .agent),
                                               NewTabPageHandler(open: { _, _ in }, jump: { _, _, _ in }, editShortcut: { _ in }))
        try #require(page.window === window && !page.isHiddenOrHasHiddenAncestor, "the page is not shown in the window")
        // The page's field has focus in its document: the readiness script's reports.
        page.inputReadiness.receive(["ready": true])
        page.inputReadiness.receive(["editing": true])
        try #require(page.inputReadiness.isReady && page.inputReadiness.isEditableFocused)
        controller.focus.send(.focusPane(pane.paneKey, source: .programmatic))
        return Fixture(services: services, controller: controller, window: window, pane: pane, page: page, key: key)
    }

    /// Cmd-T: the page shows with its field ready; the keys typed meanwhile go to it at the next key, with no readiness
    /// message and long before the hold's limit.
    @Test func cmdTKeysGoToAShownPageWhoseFieldIsReadyWithoutItsReadinessMessage() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.close() }
        let input = fixture.services.keyRouter.newTabInputCoordinator
        input.holdLimit = .seconds(600)
        input.scheduleDeadline = { _, _ in DemandTimer(owner: "test.holdLimit") }
        _ = try #require(input.begin(for: fixture.pane))
        input.didShow(in: fixture.window)
        let router = fixture.services.keyRouter
        let first = try Self.key("h", keyCode: 4, in: fixture.window)
        _ = router.interceptKeyDown(first, in: fixture.window)
        #expect(!input.isHolding(in: fixture.window), "the hold kept the keys for a shown page whose field is ready: \(input.log)")
        #expect(input.log.contains { $0.hasPrefix("drained to field") }, "the key did not go to the page's field: \(input.log)")
        #expect(fixture.window.firstResponder === fixture.page.focusTarget, "the page's field never got the keyboard")
    }

    /// A New Tab page the opening did not show (an older page the pane shows, before this opening's page) never takes
    /// its keys without the opening's token, even with its field focused.
    @Test func aPageThisOpeningDidNotShowDoesNotTakeItsKeys() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.close() }
        let input = fixture.services.keyRouter.newTabInputCoordinator
        input.holdLimit = .seconds(600)
        input.scheduleDeadline = { _, _ in DemandTimer(owner: "test.holdLimit") }
        _ = try #require(input.begin(for: fixture.pane))
        let router = fixture.services.keyRouter
        #expect(router.interceptKeyDown(try Self.key("h", keyCode: 4, in: fixture.window), in: fixture.window))
        input.flush(in: fixture.window)
        #expect(input.isHolding(in: fixture.window), "the keys went to a page this opening never showed: \(input.log)")
    }

    /// The field takes focus in its document after the keys were typed: they go there then, with no key or focus settle.
    @Test func incomingKeysGoToTheFieldWhenItTakesFocus() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.close() }
        fixture.page.inputReadiness.receive(["editing": false])
        let input = fixture.services.keyRouter.newTabInputCoordinator
        input.incomingHoldLimit = .seconds(600)
        input.scheduleDeadline = { _, _ in DemandTimer(owner: "test.holdLimit") }
        let token = try #require(input.beginIncoming(in: fixture.window, followsNewWindow: true))
        input.attachIncoming(token)
        input.pageMade(token, key: fixture.key)
        let router = fixture.services.keyRouter
        #expect(router.interceptKeyDown(try Self.key("h", keyCode: 4, in: fixture.window), in: fixture.window))
        #expect(input.isHolding(in: fixture.window), "the key went on before the page's field had focus")
        fixture.page.inputReadiness.receive(["editing": true])
        #expect(!input.isHolding(in: fixture.window), "the field took focus and the keys still wait: \(input.log)")
    }

    /// A cold New Tab page (no field yet): a native stand-in field takes the keys in the open's turn, nothing is held,
    /// and the stand-in hands its text and selection to the page's field once that has focus: one transfer, no replay.
    @Test func aColdPagesKeysGoToANativeStandInThatHandsItsTextToTheField() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.close() }
        fixture.page.inputReadiness.receive(["editing": false])  // the page's field does not exist yet
        var seeds: [NewTabFieldSeed] = []
        fixture.page.fieldSeedSink = { seeds.append($0) }
        let input = fixture.services.keyRouter.newTabInputCoordinator
        input.holdLimit = .seconds(600)
        input.scheduleDeadline = { _, _ in DemandTimer(owner: "test.holdLimit") }
        // The opening shows a page other than the one the pane showed before.
        _ = try #require(input.begin(for: fixture.pane))
        input.markShown(fixture.key, in: fixture.window)
        #expect(!input.isHolding(in: fixture.window), "a cold page's keys wait in a hold: \(input.log)")
        let standIn = try #require(fixture.page.fieldStandIn, "no stand-in field for the cold page")
        #expect(fixture.window.firstResponder === standIn, "the stand-in does not have the keyboard")
        (standIn as? NSTextView)?.insertText("hi", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(seeds.isEmpty, "the stand-in handed its text before the field existed")
        fixture.page.inputReadiness.receive(["editing": true])
        #expect(seeds == [NewTabFieldSeed(text: "hi", selectionStart: 2, selectionEnd: 2, submit: false)], "seeds \(seeds)")
        #expect(fixture.page.fieldStandIn == nil, "the stand-in stayed after it handed its text")
    }

    /// Cmd-N / Cmd-Shift-N: the hold learns its page's tab when the page is made (in the press's turn), and the keys go
    /// to it once it shows with its field ready, with no readiness message.
    @Test func incomingKeysGoToTheirPageOnceItShowsWithItsFieldReady() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.close() }
        let input = fixture.services.keyRouter.newTabInputCoordinator
        input.incomingHoldLimit = .seconds(600)
        input.scheduleDeadline = { _, _ in DemandTimer(owner: "test.holdLimit") }
        let token = try #require(input.beginIncoming(in: fixture.window, followsNewWindow: true))
        let router = fixture.services.keyRouter
        let typed = [try Self.key("h", keyCode: 4, in: fixture.window), try Self.key("i", keyCode: 34, in: fixture.window)]
        for event in typed { #expect(router.interceptKeyDown(event, in: fixture.window), "the hold did not take \(event.characters ?? "")") }
        #expect(input.isHolding(in: fixture.window))
        // The page is made for the token (AgentTabStore.showWorkspace), in this turn.
        input.attachIncoming(token)
        input.pageMade(token, key: fixture.key)
        input.flushAll()
        #expect(!input.isHolding(in: fixture.window), "the hold kept the keys for its page, shown with its field ready: \(input.log)")
        #expect(input.log.contains { $0.hasPrefix("drained to field") }, "the held keys did not go to the page's field: \(input.log)")
    }
}
