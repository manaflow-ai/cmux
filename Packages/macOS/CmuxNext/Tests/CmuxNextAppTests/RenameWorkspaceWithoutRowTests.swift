import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Rename Workspace on a pinned workspace refused with "the workspace is not in the sidebar" (Austin
/// 2026-10-25): a pin draws as a tile in the Pinned band, not as a list row, and Rename only opened
/// the list row's name field. A workspace no sidebar lists as a row now asks for its name in the
/// palette, starting from its shown name, as Rename Tab and Rename Pane do; automation that names
/// no name is still refused.
@MainActor @Suite(.serialized) struct RenameWorkspaceWithoutRowTests {
    struct Fixture {
        let services: AppServices
        let workspace: String
        let asked: () -> [(ActionID, ActionInvocation, ActionArgumentAsk)]
    }

    /// One workspace `k1` named Notes on the local daemon, and no window: no sidebar lists its row.
    static func fixture() throws -> Fixture {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let store = services.machines.local.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1"]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let pane = PaneSnapshot(id: 1, name: "Main", tabs: [TabSnapshot(surface: 1, title: "zsh", cwd: "/tmp")])
        let workspace = WorkspaceSnapshot(id: 1, key: "k1", name: "Notes", screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])],
                                          title: "Notes")
        store.apply(snapshot: DaemonTree(registryID: "s-local", workspaces: [workspace]))
        let id = try #require(store.workspaces.first?.id)
        var asked: [(ActionID, ActionInvocation, ActionArgumentAsk)] = []
        services.registry.argumentAsker = { asked.append(($0, $1, $2)) }
        return Fixture(services: services, workspace: id, asked: { asked })
    }

    @Test func aWorkspaceWithNoRowAsksForItsNameInThePalette() throws {
        let fixture = try Self.fixture()
        let target = ActionTargetRef(kind: .workspace, id: fixture.workspace)
        #expect(ActionTargetReasons.reason(for: "renameWorkspace", invocation: ActionInvocation(target: target), in: fixture.services.registry) == nil,
                "the menu row is disabled")
        let refusal = fixture.services.registry.capturingRefusal {
            _ = fixture.services.registry.perform("renameWorkspace", invocation: ActionInvocation(target: target, origin: .user))
        }
        #expect(refusal == nil, "Rename Workspace refused: \(refusal ?? "")")
        let ask = try #require(fixture.asked().first, "the palette was not asked for the name")
        #expect(ask.0 == "renameWorkspace")
        #expect(ask.1.target == target)
        #expect(ask.2 == ActionArgumentAsk(argument: "name", initialText: "Notes"))
    }

    @Test func automationWithNoNameIsStillRefused() throws {
        let fixture = try Self.fixture()
        let target = ActionTargetRef(kind: .workspace, id: fixture.workspace)
        let refusal = fixture.services.registry.capturingRefusal {
            _ = fixture.services.registry.perform("renameWorkspace", invocation: ActionInvocation(target: target, origin: .cli))
        }
        #expect(refusal != nil, "a CLI rename with no name was not refused")
        #expect(fixture.asked().isEmpty, "a CLI run opened the palette on the person's screen")
    }
}
