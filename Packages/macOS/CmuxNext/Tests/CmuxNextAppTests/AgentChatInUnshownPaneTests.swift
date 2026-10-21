import AppKit
import CmuxNextActions
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
            let window = try #require(services.windows.active)
            let shown = window.state.workspaceID
            let key = WorkspaceKey.generate()
            _ = try await WorkspaceCreation.create(key, name: "unshown", on: connection, repair: services.emptyWorkspaces) { workspace in
                try await connection.createTerminal(in: workspace, cwd: nil)
            }
            let pane = try #require(await AgentSessionWorkspace.mirroredPane(of: key, in: services.daemon.store))
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
            try await PasswordManagerRouteTests.until({ pane.tabs.count > tabs }, report: { "\(pane.tabs.count) tabs, was \(tabs)" })
            guard case .string(let tab)? = fields["tab"] else { Issue.record("no tab in \(fields)"); return }
            #expect(pane.tabs.contains { $0.id == tab }, "the chat tab is in the named pane")
            #expect(fields["shown"] == .bool(false))
            #expect(window.state.workspaceID == shown, "the window stayed on its workspace")
        }
    }
}
