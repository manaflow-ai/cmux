import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// A pinned workspace draws as a tile or top row of Pinned, not a row of the workspace list, and
/// the workspace shortcuts that work on a list row did nothing on it: Rename Workspace
/// (Cmd-Shift-R) was refused with "the workspace is not in the sidebar", and Move Workspace
/// Up/Down found no row to step from. Rename now asks the name in Cmd-Shift-P, pinned to the
/// workspace; Move steps among the items of the section that lists it.
@MainActor @Suite(.serialized) struct PinnedWorkspaceShortcutsTests {
    struct Fixture {
        let services: AppServices
        let workspace: WorkspaceModel
        let asked: () -> [(ActionID, ActionInvocation, ActionArgumentAsk)]
    }

    /// One workspace named "api" and no window: no sidebar lists a row for it, as for a pinned tile.
    static func fixture() throws -> Fixture {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let daemon = services.machines.local
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["workspace-registry-v1"]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        daemon.store.noteHandshake(identity)
        daemon.store.connectionState = .connected(identity)
        daemon.store.apply(snapshot: DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "w1"), resourceID: ResourceID(rawValue: "ws_1"), name: "api"),
        ]))
        let workspace = try #require(daemon.store.workspaces.first)
        var asked: [(ActionID, ActionInvocation, ActionArgumentAsk)] = []
        services.registry.argumentAsker = { asked.append(($0, $1, $2)) }
        return Fixture(services: services, workspace: workspace, asked: { asked })
    }

    @Test func renameWithNoListRowAsksTheNameInThePalette() throws {
        let fixture = try Self.fixture()
        let target = ActionTargetRef(kind: .workspace, id: fixture.workspace.id)
        var ran = false
        let reason = fixture.services.registry.capturingRefusal {
            ran = fixture.services.registry.perform("renameWorkspace", invocation: ActionInvocation(target: target))
        }
        #expect(reason == nil, "Rename on a workspace with no list row was refused: \(reason ?? "")")
        #expect(ran)
        let ask = try #require(fixture.asked().first, "the palette was not asked for the name")
        #expect(ask.0 == "renameWorkspace")
        #expect(ask.1.target == target, "the answer must rename this workspace, whatever shows then")
        #expect(ask.2 == ActionArgumentAsk(argument: "name", initialText: "api"))
    }

    @Test func homeWithNoListRowStillKeepsItsName() throws {
        let fixture = try Self.fixture()
        fixture.workspace.kind = "home"
        let reason = fixture.services.registry.capturingRefusal {
            _ = fixture.services.registry.perform("renameWorkspace",
                                                  invocation: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: fixture.workspace.id)))
        }
        #expect(reason != nil, "Home was offered a rename")
        #expect(fixture.asked().isEmpty)
    }
}
