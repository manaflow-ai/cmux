import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// SPLIT OPEN CHAT (films of hold f7a, 2026-11-10): the new pane of a chat split showed its chat's ground, then the
/// window's color for 2 to 3 frames at 120 Hz, then the ground again. A new chat shows as a provisional tab until the
/// store has its tab, which replaces it under another id; the chat's page and view state move to that id
/// (`AgentTabs.tabCreated`). The pane's strip takes the record's tabs on its next apply, a main-actor turn later. A
/// frame of the presentation scheduler between the two showed the selection of the strip as it was: the provisional
/// tab, which the record no longer listed, so the pane showed nothing and hid the chat it was showing (its ground is
/// in that view), until the apply showed the same view again.
@Suite(.serialized, .closesItsWindows)
@MainActor struct NewChatKeepsItsPageThroughTheStoresSwapTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static let realTab = "tab_split_open_chat_real"
    private static let made = SurfaceID(rawValue: 3)

    /// One pane: two terminals, and the store's chat tab when `withChat`.
    private static func tree(withChat: Bool) -> DaemonTree {
        var tabs = [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~"), TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~")]
        if withChat {
            var chat = TabSnapshot(surface: made, tabResourceID: ResourceID(rawValue: realTab), kind: .conversation,
                                   title: "chat", browserRenderer: "frontend")
            chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:test", session: nil, harness: nil))
            tabs.append(chat)
        }
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: tabs)
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    /// What a person sees of the chat in `pane`: nil while the pane shows it, else what is wrong.
    private static func fault(of chat: AgentPaneView, in pane: PaneController) -> String? {
        if pane.view.content !== chat { return "the pane shows \(pane.view.content.map { String(describing: type(of: $0)) } ?? "nothing"), not the chat" }
        if chat.superview !== pane.view.contentHost { return "the chat is not in the pane's content area" }
        if chat.isHidden { return "the chat is hidden" }
        return nil
    }

    @Test(.timeLimit(.minutes(1))) func theChatStaysShownWhileTheStoresTabReplacesItsProvisionalTab() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        let identity = #"{"app":"cmux-tui","protocol":1,"session":"new-chat-swap-test","generation":"g1"}"#
        store.connectionState = .connected(try JSONDecoder().decode(DaemonIdentity.self, from: Data(identity.utf8)))
        store.apply(snapshot: Self.tree(withChat: false))
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services, state: state)
        defer { pane.teardown() }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        pane.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        window.contentView = pane.view
        window.orderFrontRegardless()
        pane.syncStripFromStore()
        pane.view.layoutSubtreeIfNeeded()

        // A new chat (AgentTabs.open): its page is made under the provisional tab's id, and the tab shows and is selected now.
        let directory = FileManager.default.temporaryDirectory.appending(path: "new-chat-swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html><body></body></html>".utf8).write(to: file)
        let chat = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "s-new-chat"), source: .bundled(file),
                                              pageHost: true, chromium: nil))
        defer { chat.close() }
        let machine = pane.daemon.machineID
        let provisional = ProvisionalTab()
        let provisionalKey = AgentTabKey(machine: machine, key: provisional.id), realKey = AgentTabKey(machine: machine, key: Self.realTab)
        services.agentTabs.views[provisionalKey] = chat
        defer {
            services.agentTabs.views[provisionalKey] = nil
            services.agentTabs.views[realKey] = nil
        }
        let page = provisional.conversation(ConversationTabRef(agentSession: AgentSessionRef(host: "install:test", session: nil, harness: nil)))
        let transaction = ClientTransactionID.generate()
        store.intend(.createTab(pane: model.handle, provisional: page), transaction: transaction)
        pane.selectWhenReported(surface: provisional.surface)
        try #require(pane.currentTabKey == provisional.id, "the pane does not show the provisional chat tab")
        try #require(Self.fault(of: chat, in: pane) == nil, "the new chat never showed: \(Self.fault(of: chat, in: pane) ?? "")")

        // The store answers (AgentTabs.open's reply): the page and the selection move to the store's tab...
        services.agentTabs.tabCreated(provisional.id, as: AgentTabCreated(key: Self.realTab, surface: Self.made), machine: machine)
        pane.selectWhenReported(surface: Self.made) // `moveSelection`, for the pane that has the provisional tab selected
        #expect(Self.fault(of: chat, in: pane) == nil, "the reply took the chat away: \(Self.fault(of: chat, in: pane) ?? "")")
        // ...and the store's tab replaces the provisional one in the record. The strip has not taken that yet.
        ProvisionalTab.created(transaction, surface: Self.made, in: store)
        store.apply(snapshot: Self.tree(withChat: true))
        try #require(store.tab(surface: Self.made)?.id == Self.realTab, "the store does not list the chat's tab")
        try #require(!pane.pane.tabs.contains(where: { $0.id == provisional.id }), "the record still lists the provisional tab")

        // A frame of the presentation scheduler comes before the strip's apply (ContentPresentationScheduler.drain).
        pane.showSelected()
        #expect(Self.fault(of: chat, in: pane) == nil,
                "a frame between the store's swap and the strip's apply: \(Self.fault(of: chat, in: pane) ?? "")")

        // Each later step up to the show of the store's tab.
        var faults: [String] = []
        let start = ContinuousClock.now
        while pane.currentTabKey != Self.realTab, ContinuousClock.now < start.advanced(by: .milliseconds(300)) {
            if let fault = Self.fault(of: chat, in: pane) { faults.append(fault) }
            try await Task.sleep(for: .milliseconds(4))
        }
        #expect(faults.isEmpty, "the chat went away before the store's tab showed: \(faults)")
        #expect(pane.currentTabKey == Self.realTab, "the pane never showed the store's tab (it shows \(pane.currentTabKey ?? "nothing"))")
        #expect(Self.fault(of: chat, in: pane) == nil, "the store's tab does not show the chat: \(Self.fault(of: chat, in: pane) ?? "")")
    }
}
