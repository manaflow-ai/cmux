import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// cx-bun: New Agent Chat and Add Harness… from Home (a top page over the
/// window's parked workspace) open a new workspace with the chat, as Cmd-I
/// does from any workspace. Before, both waited for a pane the parked
/// workspace never shows and were refused ("No pane is focused").
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct AgentChatFromHomeTests {
    @Test(arguments: [
        ("palette.newAgentChat", ActionOrigin.user),
        ("palette.newAgentChat", ActionOrigin.cli),
        ("palette.addHarness", ActionOrigin.user),
    ])
    func fromHomeTheActionOpensANewWorkspace(_ action: String, _ origin: ActionOrigin) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let window = try #require(services.windows.active)
            #expect(window.showTopPage(.home))
            #expect(window.focusedPane == nil, "Home shows no pane")
            let before = Set(services.daemon.store.workspaces.map(\.id))
            let invocation = ActionInvocation(origin: origin, focusRequested: origin != .user)
            #expect(services.registry.perform(ActionID(rawValue: action), invocation: invocation))
            try await PasswordManagerRouteTests.until {
                services.daemon.store.workspaces.contains { !before.contains($0.id) }
            }
            let created = try #require(services.daemon.store.workspaces.first { !before.contains($0.id) })
            try await PasswordManagerRouteTests.until { window.state.workspaceID == created.id && window.state.page == nil }
        }
    }
}
