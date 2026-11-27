import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDaemon
import Foundation
import Testing

/// #23026: `cmux agents chat new --pane|--workspace` shows the chat it started through
/// `agent.openSessionTab` (`cmux agent open-tab SESSION`): an existing acpmux session as a chat
/// tab of a pane, also one no window shows. The run answers the tab, pane, workspace and
/// workspace key, so the caller can find its chat, and a script's run leaves the window and the
/// person's selected tab where they were. Pattern from `AgentChatInUnshownPaneTests` (#23016,
/// https://github.com/manaflow-ai/cmux/pull/23085).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct AgentSessionInUnshownPaneTests {
    @Test func aScriptShowsASessionInAPaneNoWindowShows() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-23026")
            try #require(services.agentTabs.canHostChat, "this build has no agent page")
            let window = try #require(services.windows.active)
            let shown = window.state.workspaceID
            let key = WorkspaceKey.generate()
            _ = try await WorkspaceCreation.create(key, name: "unshown", on: connection, repair: services.emptyWorkspaces) { workspace in
                try await connection.createTerminal(in: workspace, cwd: nil)
            }
            let pane = try #require(await services.daemon.store.firstPane(mirroring: key))
            #expect(services.paneController(for: pane) == nil, "no window shows the new workspace")
            let tabs = pane.tabs.count

            let run = RegistryControlBridge(registry: services.registry).performActionTracked(
                ControlActionRequest(actionID: "agent.openSessionTab", target: ControlTargetRef(kind: "pane", id: pane.id),
                                     arguments: ["session": .string("acp-23026")], origin: ActionOrigin.cli.rawValue)
            )
            #expect(run.outcome == .ran, "\(run.outcome)")
            let fields = try #require(await run.results.first?.value.get())
            guard case .string(let tab)? = fields["tab"] else { Issue.record("no tab in \(fields)"); return }
            // The run answers the store's tab id once the daemon replied, which can be before the
            // store applied the daemon's events: the pane still shows the provisional stand-in (it
            // already counts as one more tab), and the store's tab replaces it when they apply.
            try await PasswordManagerRouteTests.until({ pane.tabs.contains { $0.id == tab || $0.resourceID?.rawValue == tab } }, report: {
                "the chat tab \(tab) is in the named pane; it holds \(pane.tabs.map(\.id)), \(tabs) before"
            })
            #expect(pane.tabs.count == tabs + 1, "\(pane.tabs.map(\.id))")
            #expect(fields["session"] == .string("acp-23026"))
            #expect(fields["workspace_key"] == .string(key.rawValue))
            #expect(window.state.workspaceID == shown, "the window stayed on its workspace")
        }
    }

    /// A pane a window shows: the script's chat joins its strip, and the tab the person looks at
    /// stays selected.
    @Test func aScriptShowsASessionInAShownPaneWithoutChangingItsSelection() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-23026")
            try #require(services.agentTabs.canHostChat, "this build has no agent page")
            let window = try #require(services.windows.active)
            try await PasswordManagerRouteTests.until { window.focusedPane?.stripModel.selectedID != nil }
            let controller = try #require(window.focusedPane)
            let selected = controller.stripModel.selectedID
            let tabs = controller.pane.tabs.count
            let run = RegistryControlBridge(registry: services.registry).performActionTracked(
                ControlActionRequest(actionID: "agent.openSessionTab", target: ControlTargetRef(kind: "pane", id: controller.pane.id),
                                     arguments: ["session": .string("acp-23026-shown")], origin: ActionOrigin.cli.rawValue)
            )
            #expect(run.outcome == .ran, "\(run.outcome)")
            let fields = try #require(await run.results.first?.value.get())
            guard case .string(let tab)? = fields["tab"] else { Issue.record("no tab in \(fields)"); return }
            // The reply can precede the store's events (see above): wait for the store's tab itself.
            try await PasswordManagerRouteTests.until({ controller.pane.tabs.contains { $0.id == tab || $0.resourceID?.rawValue == tab } }, report: {
                "the chat tab \(tab) is in the pane; it holds \(controller.pane.tabs.map(\.id)), \(tabs) before"
            })
            #expect(controller.pane.tabs.count == tabs + 1, "\(controller.pane.tabs.map(\.id))")
            #expect(controller.stripModel.selectedID == selected, "the person's selected tab changed")
        }
    }
}
