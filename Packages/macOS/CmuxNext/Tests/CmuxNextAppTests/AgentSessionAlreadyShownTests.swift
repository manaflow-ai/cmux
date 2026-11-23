import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDaemon
import Foundation
import Testing

/// ask-a0466e9c05 (Leo: "can you show me interim-coord-2 in my workspace?"): `cmux agent open-tab`
/// (`agent.openSessionTab`) of a session the app counted as already shown answered success with no
/// tab, no ids and no error, so the script could not tell where the chat was and nothing showed.
/// An existing tab now counts only while it is a live tab in a pane of a listed workspace, and the
/// run answers its tab, pane and workspace ids as the new-tab path does; a binding that resolves to
/// no tab is passed over and a new tab opens. `agent.openSessionWorkspace` answers the same ids.
/// Pattern from `AgentSessionInUnshownPaneTests` (#23026).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct AgentSessionAlreadyShownTests {
    private static func openTab(_ services: AppServices, session: String, pane: PaneModel) -> ControlActionRun {
        RegistryControlBridge(registry: services.registry).performActionTracked(
            ControlActionRequest(actionID: "agent.openSessionTab", target: ControlTargetRef(kind: "pane", id: pane.id),
                                 arguments: ["session": .string(session)], origin: ActionOrigin.cli.rawValue)
        )
    }

    private static func string(_ value: ActionResultValue?) -> String? {
        if case .string(let text)? = value { return text }
        return nil
    }

    /// A script's second open of a session a tab already shows adds no tab and answers that tab,
    /// its pane and its workspace (it answered nothing before).
    @Test func aScriptOpenOfAShownSessionAnswersItsTab() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-shown")
            try #require(services.agentTabs.canHostChat, "this build has no agent page")
            let session = "acp-shown-\(UUID().uuidString.prefix(8).lowercased())"
            let key = WorkspaceKey.generate()
            _ = try await WorkspaceCreation.create(key, name: "shown", on: connection, repair: services.emptyWorkspaces) { workspace in
                try await connection.createTerminal(in: workspace, cwd: nil)
            }
            let pane = try #require(await services.daemon.store.firstPane(mirroring: key))
            let first = Self.openTab(services, session: session, pane: pane)
            #expect(first.outcome == .ran, "\(first.outcome)")
            let opened = try #require(await first.results.first?.value.get())
            let tab = try #require(Self.string(opened["tab"]), "no tab in \(opened)")
            try await PasswordManagerRouteTests.until({ services.agentTabs.tab(showing: session) != nil && pane.tabs.contains { $0.resourceID?.rawValue == tab || $0.id == tab } }, report: {
                "the chat tab \(tab) is listed in the pane; it holds \(pane.tabs.map(\.id))"
            })
            let tabs = pane.tabs.count

            // Opened again from another pane (the coordinator's `--target <fresh pane>`): the shown tab answers.
            let other = try #require(services.windows.active?.focusedPane?.pane)
            let again = Self.openTab(services, session: session, pane: other)
            #expect(again.outcome == .ran, "\(again.outcome)")
            let answered = try #require(await again.results.first?.value.get(), "the run answered no result")
            #expect(Self.string(answered["session"]) == session)
            #expect(Self.string(answered["tab"]) == tab, "answered \(answered), the shown tab is \(tab)")
            #expect(Self.string(answered["pane"]) == (pane.resourceID?.rawValue ?? pane.id))
            #expect(Self.string(answered["workspace_key"]) == key.rawValue)
            #expect(answered["workspace"] != nil)
            #expect(pane.tabs.count == tabs, "a second tab opened: \(pane.tabs.map(\.id))")
        }
    }

    /// A binding to a tab no store holds (its tab, pane or workspace gone) is not a shown chat: the
    /// open makes a new tab in the named pane and answers it, never success with nothing.
    @Test func aStaleBindingOpensANewTab() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let tabs = services.agentTabs
            tabs.localHost = AgentSessionRef.host(installID: "cn-stale")
            try #require(tabs.canHostChat, "this build has no agent page")
            let host = try #require(tabs.localHost)
            let session = "acp-stale-\(UUID().uuidString.prefix(8).lowercased())"
            let listed = tabs.listTabsScoped
            tabs.listTabsScoped = { [listed] in
                listed() + [(key: "tab_gone_\(session)", record: AgentSessionRef(host: host, session: session), machine: services.daemon.machineID)]
            }
            defer { tabs.listTabsScoped = listed }
            #expect(tabs.tab(showing: session) == "tab_gone_\(session)", "the stale binding is listed")
            #expect(AgentSessionTab.liveTab(showing: session, host: nil, services: services) == nil, "a tab no store holds counted as live")

            let key = WorkspaceKey.generate()
            _ = try await WorkspaceCreation.create(key, name: "stale", on: connection, repair: services.emptyWorkspaces) { workspace in
                try await connection.createTerminal(in: workspace, cwd: nil)
            }
            let pane = try #require(await services.daemon.store.firstPane(mirroring: key))
            let before = pane.tabs.count
            let run = Self.openTab(services, session: session, pane: pane)
            #expect(run.outcome == .ran, "\(run.outcome)")
            let fields = try #require(await run.results.first?.value.get(), "the run answered no result")
            let tab = try #require(Self.string(fields["tab"]), "no tab in \(fields)")
            #expect(tab != "tab_gone_\(session)", "answered the stale binding")
            try await PasswordManagerRouteTests.until({ pane.tabs.contains { $0.id == tab || $0.resourceID?.rawValue == tab } }, report: {
                "the new chat tab \(tab) is in the pane; it holds \(pane.tabs.map(\.id)), \(before) before"
            })
            #expect(pane.tabs.count == before + 1, "\(pane.tabs.map(\.id))")
            #expect(Self.string(fields["workspace_key"]) == key.rawValue)
        }
    }

    /// `agent.openSessionWorkspace` answers the chat's tab, pane and workspace, and a run again with the same key
    /// (a launcher's retry) answers the same tab instead of nothing.
    @Test func openSessionWorkspaceAnswersItsTabAndAgainTheSame() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-shown-ws")
            try #require(services.agentTabs.canHostChat, "this build has no agent page")
            let session = "acp-shown-ws-\(UUID().uuidString.prefix(8).lowercased())"
            let key = WorkspaceKey.generate()
            let open = {
                RegistryControlBridge(registry: services.registry).performActionTracked(
                    ControlActionRequest(actionID: "agent.openSessionWorkspace", target: nil,
                                         arguments: ["session": .string(session), "name": .string("shown lane"), "key": .string(key.rawValue)],
                                         origin: ActionOrigin.cli.rawValue)
                )
            }
            let first = open()
            #expect(first.outcome == .ran, "\(first.outcome)")
            let opened = try #require(await first.results.first?.value.get(), "the run answered no result")
            let tab = try #require(Self.string(opened["tab"]), "no tab in \(opened)")
            #expect(Self.string(opened["workspace_key"]) == key.rawValue)
            #expect(opened["pane"] != nil)
            try await PasswordManagerRouteTests.until({ AgentSessionTab.liveTab(showing: session, host: nil, services: services, in: key.rawValue) != nil }, report: {
                "the chat tab \(tab) is listed in workspace \(key.rawValue)"
            })

            let again = open()
            #expect(again.outcome == .ran, "\(again.outcome)")
            let answered = try #require(await again.results.first?.value.get(), "the run again answered no result")
            #expect(Self.string(answered["tab"]) == tab, "answered \(answered), the chat is in \(tab)")
            #expect(Self.string(answered["workspace_key"]) == key.rawValue)
        }
    }
}
