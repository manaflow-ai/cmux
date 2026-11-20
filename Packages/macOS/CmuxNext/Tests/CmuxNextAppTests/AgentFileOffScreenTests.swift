import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import Foundation
import Testing

/// An agent's `cmux open FILE` whose workspace no window shows (the person looks at Home) opens the
/// file as a tab in that workspace, and the person's view stays where it is (user, 2026-11-18).
/// Before, `file.open` needed a pane on screen and refused: "pane:… is not shown in any window".
@MainActor @Suite(.serialized, .closesItsWindows)
struct AgentFileOffScreenTests {
    @Test(arguments: ["notes.md", "main.swift"])
    func anAgentsFileOpensAsATabInItsWorkspaceOffScreen(name: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-file-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(name)
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)
        try await PasswordManagerRouteTests.withApp { services, connection in
            let window = try #require(services.windows.active)
            try await PasswordManagerRouteTests.until({ window.focusedPane != nil }, report: { "the first workspace never showed a pane" })
            // The agent's workspace: the one the window showed first, parked when Home shows.
            let agentPane = try #require(window.focusedPane).pane
            let (_, home) = try await HomeSplitKeysTests.showHome(services, connection)
            try await PasswordManagerRouteTests.until({ services.paneController(for: agentPane) == nil },
                                                      report: { "the agent's workspace is still on screen" })
            let before = agentPane.tabs.count
            let invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: agentPane.id),
                                              arguments: ["path": .string(file.path)], origin: .cli)
            let refusal = services.registry.capturingRefusal { _ = services.registry.perform(.fileOpen, invocation: invocation) }
            #expect(refusal == nil, "\(refusal ?? "")")
            try await PasswordManagerRouteTests.until({ agentPane.tabs.count == before + 1 },
                                                      report: { "no tab opened in the agent's workspace: \(agentPane.tabs.count) tab(s)" })
            #expect(window.state.workspaceID == home.id, "the person's view stays on Home")
        }
    }
}
