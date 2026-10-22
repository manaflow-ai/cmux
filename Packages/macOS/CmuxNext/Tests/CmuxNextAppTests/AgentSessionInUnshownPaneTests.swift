import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDaemon
import Foundation
import Testing

/// #23026: `cmux agent open SESSION --pane|--workspace` and `cmux agents chat new` show an
/// existing acpmux session as a chat tab of a pane or workspace no window shows. The tab opens on
/// the workspace store in that pane (a workspace's most recently focused one), the window stays on
/// its workspace, and the run answers the tab, pane, workspace and workspace key. Pattern from
/// `AgentChatInUnshownPaneTests` (#23016, https://github.com/manaflow-ai/cmux/pull/23085).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct AgentSessionInUnshownPaneTests {
    @Test(arguments: ["pane", "workspace"])
    func aScriptShowsASessionInAWorkspaceNoWindowShows(_ kind: String) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-23026")
            try #require(services.agentTabs.canHostChat, "this build has no agent page")
            let window = try #require(services.windows.active)
            let shown = window.state.workspaceID
            let key = WorkspaceKey.generate()
            _ = try await WorkspaceCreation.create(key, name: "unshown", on: connection, repair: services.emptyWorkspaces) { workspace in
                try await connection.createTerminal(in: workspace, cwd: nil)
            }
            let pane = try #require(await AgentSessionWorkspace.mirroredPane(of: key, in: services.daemon.store))
            let workspace = try #require(services.daemon.store.workspaces.first { $0.key == key })
            #expect(services.paneController(for: pane) == nil, "no window shows the new workspace")
            let tabs = pane.tabs.count

            let place = kind == "pane"
                ? ControlTargetRef(kind: "pane", id: pane.resourceID?.rawValue ?? pane.id)
                : ControlTargetRef(kind: "workspace", id: workspace.resourceID?.rawValue ?? workspace.id)
            let run = RegistryControlBridge(registry: services.registry).performActionTracked(
                ControlActionRequest(actionID: "agent.openSessionWorkspace",
                                     arguments: ["session": .string("acp-23026"), kind: .target(place)],
                                     origin: ActionOrigin.cli.rawValue)
            )
            #expect(run.outcome == .ran, "\(run.outcome)")
            let fields = try #require(await run.results.first?.value.get())
            try await PasswordManagerRouteTests.until({ pane.tabs.count > tabs }, report: { "\(pane.tabs.count) tabs, was \(tabs)" })
            guard case .string(let tab)? = fields["tab"] else { Issue.record("no tab in \(fields)"); return }
            #expect(pane.tabs.contains { $0.id == tab || $0.resourceID?.rawValue == tab }, "the chat tab is in the named pane")
            #expect(fields["session"] == .string("acp-23026"))
            #expect(fields["workspace_key"] == .string(key.rawValue))
            #expect(window.state.workspaceID == shown, "the window stayed on its workspace")
        }
    }
}
