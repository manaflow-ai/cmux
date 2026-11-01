import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDaemon
import Foundation
import Testing

/// #23016: New Agent Chat run by a script or agent on a pane or workspace that no window shows.
/// Before, the action looked for the pane among the windows' mounted panes and was refused
/// ("That pane is no longer open"), so the CLI and MCP could not start a GUI chat without
/// switching the person's window to it. Now the tab opens on the workspace store, the window
/// stays where it was, and the run answers the new tab's ids.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct AgentChatInUnshownPaneTests {
    @Test(arguments: [ActionTargetKind.pane, .workspace])
    func aScriptOpensAChatInAWorkspaceNoWindowShows(_ kind: ActionTargetKind) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-23016")
            try #require(services.agentTabs.canHostChat, "this build has no agent page")
            let window = try #require(services.windows.active)
            let shown = window.state.workspaceID
            let key = WorkspaceKey.generate()
            _ = try await WorkspaceCreation.create(key, name: "unshown", on: connection, repair: services.emptyWorkspaces) { workspace in
                try await connection.createTerminal(in: workspace, cwd: nil)
            }
            let pane = try #require(await services.daemon.store.firstPane(mirroring: key))
            let workspace = try #require(services.daemon.store.workspaces.first { $0.key == key })
            #expect(services.paneController(for: pane) == nil, "no window shows the new workspace")
            #expect(window.state.workspaceID == shown)
            let tabs = pane.tabs.count

            let target = kind == .pane ? ActionTargetRef(kind: .pane, id: pane.resourceID?.rawValue ?? pane.id)
                : ActionTargetRef(kind: .workspace, id: workspace.id)
            let run = RegistryControlBridge(registry: services.registry).performActionTracked(
                ControlActionRequest(actionID: "palette.newAgentChat", target: ControlTargetRef(kind: target.kind.rawValue, id: target.id),
                                     origin: ActionOrigin.cli.rawValue)
            )
            #expect(run.outcome == .ran, "\(run.outcome)")
            let fields = try #require(await run.results.first?.value.get())
            guard case .string(let tab)? = fields["tab"] else { Issue.record("no tab in \(fields)"); return }
            // The run answers the store's tab id once the daemon replied, which can be before the
            // store applied the daemon's events: the pane still shows the provisional stand-in (it
            // already counts as one more tab), and the store's tab replaces it when they apply.
            try await PasswordManagerRouteTests.until({ pane.tabs.contains { $0.id == tab } }, report: {
                "the chat tab \(tab) is in the named pane; it holds \(pane.tabs.map(\.id)), \(tabs) before"
            })
            #expect(pane.tabs.count == tabs + 1, "\(pane.tabs.map(\.id))")
            #expect(fields["workspace_key"] == .string(key.rawValue))
            #expect(window.state.workspaceID == shown, "the window stayed on its workspace")
        }
    }

    /// A pane a window shows: the script's chat joins its strip, and the tab the person looks at
    /// stays selected (the run still answers the chat's ids and changes no focus).
    @Test func aScriptOpensAChatInAShownPaneWithoutChangingItsSelection() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-23016")
            try #require(services.agentTabs.canHostChat, "this build has no agent page")
            let window = try #require(services.windows.active)
            try await PasswordManagerRouteTests.until { window.focusedPane?.stripModel.selectedID != nil }
            let controller = try #require(window.focusedPane)
            let selected = controller.stripModel.selectedID
            let tabs = controller.pane.tabs.count
            let run = RegistryControlBridge(registry: services.registry).performActionTracked(
                ControlActionRequest(actionID: "palette.newAgentChat", target: ControlTargetRef(kind: "pane", id: controller.paneKey),
                                     origin: ActionOrigin.cli.rawValue)
            )
            #expect(run.outcome == .ran, "\(run.outcome)")
            let fields = try #require(await run.results.first?.value.get())
            guard case .string(let tab)? = fields["tab"] else { Issue.record("no tab in \(fields)"); return }
            // The reply can precede the store's events (see above): wait for the store's tab itself.
            try await PasswordManagerRouteTests.until({ controller.pane.tabs.contains { $0.id == tab } }, report: {
                "the chat tab \(tab) is in the pane; it holds \(controller.pane.tabs.map(\.id)), \(tabs) before"
            })
            #expect(controller.pane.tabs.count == tabs + 1, "\(controller.pane.tabs.map(\.id))")
            #expect(controller.stripModel.selectedID == selected, "the person's selected tab changed")
        }
    }

    /// A user-targeted pane action permits view changes, so the explicit pane still wins over
    /// the untargeted top-page placement route.
    @Test func aUserTargetedChatOpensInAShownPane() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-28064-target")
            try #require(services.agentTabs.canHostChat, "this build has no agent page")
            let window = try #require(services.windows.active)
            let controller = try #require(window.focusedPane)
            let tabs = controller.pane.tabs.count
            let run = RegistryControlBridge(registry: services.registry).performActionTracked(
                ControlActionRequest(actionID: "palette.newAgentChat",
                                     target: ControlTargetRef(kind: "pane", id: controller.paneKey),
                                     origin: ActionOrigin.user.rawValue)
            )
            #expect(run.outcome == .ran, "\(run.outcome)")
            try await PasswordManagerRouteTests.until({ controller.pane.tabs.count > tabs },
                                                      report: { "\(controller.pane.tabs.count) tabs, was \(tabs)" })
        }
    }

    /// The action's explicit folder reaches the created tab, rather than being dropped by the
    /// untargeted/targeted open paths. This observes the store's created tab after the action.
    @Test func aTargetedChatKeepsTheRequestedCwd() async throws {
        try await AgentChatActionFixture.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-23016-cwd")
            try #require(services.agentTabs.canHostChat, "this build has no agent page")
            let window = try #require(services.windows.active)
            let pane = try #require(window.focusedPane)
            let before = Set(PasswordManagerRouteTests.tabs(services).map(\.id))
            let run = RegistryControlBridge(registry: services.registry).performActionTracked(
                ControlActionRequest(actionID: "palette.newAgentChat", target: ControlTargetRef(kind: "pane", id: pane.paneKey),
                                     arguments: ["cwd": .string(AgentChatActionFixture.localCwd)], origin: ActionOrigin.cli.rawValue)
            )
            let fields = try await AgentChatActionFixture.finish(run)
            let created = try await AgentChatActionFixture.created(in: services, after: before, fields: fields)
            #expect(pane.pane.tabs.contains { $0.id == created.id })
            // Automation keeps the tab unselected. Instantiate its actual page and ask the
            // same ready request as the webview; existingView alone never mounts an unseen tab.
            let view = try #require(services.agentTabs.view(for: created.id))
            let reply = await view.model.respond(to: AgentPaneRequest(body: ["method": "ready"]))
            let handshake = try #require(reply["value"] as? [String: Any], "\(reply)")
            #expect(handshake["cwd"] as? String == AgentChatActionFixture.localCwd)
            #expect(view.model.handshakeCwd == AgentChatActionFixture.localCwd)
        }
    }

    @Test func anUntargetedChatKeepsTheRequestedCwd() async throws {
        try await AgentChatActionFixture.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-23016-cwd-untargeted")
            try #require(services.agentTabs.canHostChat, "this build has no agent page")
            let before = Set(PasswordManagerRouteTests.tabs(services).map(\.id))
            let run = RegistryControlBridge(registry: services.registry).performActionTracked(
                ControlActionRequest(actionID: "palette.newAgentChat", arguments: ["cwd": .string(AgentChatActionFixture.localCwd)],
                                     origin: ActionOrigin.cli.rawValue))
            let fields = try await AgentChatActionFixture.finish(run)
            let created = try await AgentChatActionFixture.created(in: services, after: before, fields: fields)
            // Automation keeps the tab unselected. Instantiate its actual page and ask the
            // same ready request as the webview; existingView alone never mounts an unseen tab.
            let view = try #require(services.agentTabs.view(for: created.id))
            let reply = await view.model.respond(to: AgentPaneRequest(body: ["method": "ready"]))
            let handshake = try #require(reply["value"] as? [String: Any], "\(reply)")
            #expect(handshake["cwd"] as? String == AgentChatActionFixture.localCwd)
            #expect(view.model.handshakeCwd == AgentChatActionFixture.localCwd)
        }
    }

}
