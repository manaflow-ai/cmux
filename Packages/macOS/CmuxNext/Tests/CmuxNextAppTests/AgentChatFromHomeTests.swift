import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Testing

/// cx-bun: New Agent Chat and Add Harness… from Home (a top page over the
/// window's parked workspace) open a new workspace with the chat, as Cmd-I
/// does from any workspace. Before, both waited for a pane the parked
/// workspace never shows and were refused ("No pane is focused").
/// Since cx-ebm.59.5 Home is the home workspace with its left dock, where a chat
/// opens in a pane as from any workspace; Home is a top page only as classic Home
/// (`labs.classicHome`), which these tests turn on.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct AgentChatFromHomeTests {
    /// A script without focus gets the workspace but leaves the window on Home.
    @Test(arguments: [
        ("palette.newAgentChat", ActionOrigin.user, true),
        ("palette.newAgentChat", ActionOrigin.cli, true),
        ("palette.newAgentChat", ActionOrigin.cli, false),
        ("palette.addHarness", ActionOrigin.user, true),
    ])
    func fromHomeTheActionOpensANewWorkspace(_ action: String, _ origin: ActionOrigin, _ focus: Bool) async throws {
        let classic = DesignSettings.shared.classicHome
        DesignSettings.shared.classicHome = true
        defer { DesignSettings.shared.classicHome = classic }
        try await PasswordManagerRouteTests.withApp { services, _ in
            let window = try #require(services.windows.active)
            #expect(TopPages.show(.home, services: services) != nil)
            #expect(window.state.page == .home)
            #expect(window.focusedPane == nil, "Home shows no pane")
            let before = Set(services.daemon.store.workspaces.map(\.id))
            let invocation = ActionInvocation(origin: origin, focusRequested: origin != .user && focus)
            #expect(services.registry.perform(ActionID(rawValue: action), invocation: invocation))
            try await PasswordManagerRouteTests.until {
                services.daemon.store.workspaces.contains { !before.contains($0.id) }
            }
            let created = try #require(services.daemon.store.workspaces.first { !before.contains($0.id) })
            if origin == .user || focus {
                try await PasswordManagerRouteTests.until { window.state.workspaceID == created.id && window.state.page == nil }
            } else {
                #expect(window.state.page == .home, "a script without focus switched the window")
            }
        }
    }
}
