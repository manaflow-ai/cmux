import CmuxNextActions
import CmuxNextCloud
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Cloud terminals from the CLI (audit §2b): `cloud ssh` answers the new tab's ids, and
/// `cloud new-terminal-on-machine --workspace <id>` adds a terminal tab to that workspace of the
/// machine instead of making a workspace. An unknown workspace names the machine and the
/// command that makes one.
@MainActor @Suite(.serialized)
struct CloudTerminalTests {
    /// A machine whose daemon holds one workspace (`ws-key-1`, `ws_one`) with one pane.
    static func machineWithWorkspace() -> (services: AppServices, context: AppActionContext, session: CloudMachineSession) {
        let f = CloudCLITargetTests.fixture()
        let pane = PaneSnapshot(id: PaneID(rawValue: 7), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 70), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        f.session.daemon.store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "ws-key-1"),
                              resourceID: ResourceID(rawValue: "ws_one"), name: "one", screens: [screen]),
        ]))
        return f
    }

    @Test func noWorkspaceArgumentMakesAWorkspace() throws {
        #expect(try CloudHandlers.machineWorkspaceArgument(ActionInvocation(origin: .cli), machine: "vm-a") == nil)
    }

    @Test func theWorkspaceArgumentIsTrimmed() throws {
        let invocation = ActionInvocation(arguments: ["workspace": .string("  ws_one \n")], origin: .cli)
        #expect(try CloudHandlers.machineWorkspaceArgument(invocation, machine: "vm-a") == "ws_one")
    }

    /// `--workspace` with no value reaches the action as `true`; blank text refuses the same way,
    /// with the machine's own command.
    @Test(arguments: [ActionValue.bool(true), .string("  ")])
    func aWorkspaceFlagWithoutAnIdSaysHowToPassOne(value: ActionValue) {
        let invocation = ActionInvocation(arguments: ["workspace": value], origin: .cli)
        #expect(throws: ActionFailure(message: CloudStrings.machineWorkspaceRequired("vm-a"))) {
            try CloudHandlers.machineWorkspaceArgument(invocation, machine: "vm-a")
        }
        #expect(CloudStrings.machineWorkspaceRequired("vm-a").contains("cmux cloud new-terminal-on-machine --target machine:vm-a"))
    }

    @Test func anUnknownWorkspaceIsNotFoundAndNamesTheMachineAndTheNextCommand() async {
        let f = Self.machineWithWorkspace()
        do {
            _ = try await CloudHandlers.machineWorkspace("ws_gone", on: f.session)
            Issue.record("an unknown workspace resolved")
        } catch let failure as ActionFailure {
            #expect(failure.isNotFound)
            #expect(failure.message == CloudStrings.noSuchMachineWorkspace(f.session.machineID, "ws_gone"))
            #expect(failure.message.contains("`\(f.session.machineID)`"))
            #expect(failure.message.contains("`ws_gone`"))
            #expect(failure.message.contains("cmux cloud new-terminal-on-machine --target machine:\(f.session.machineID)"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    /// The workspace resolves by the id an earlier run answered, or by its `ws_…` id, to its
    /// durable key and first pane: where the new tab lands.
    @Test(arguments: ["ws-key-1", "ws_one"])
    func aKnownWorkspaceResolvesToItsKeyAndFirstPane(requested: String) async throws {
        let f = Self.machineWithWorkspace()
        let anchor = try await CloudHandlers.machineWorkspace(requested, on: f.session)
        #expect(anchor.id == "ws-key-1")
        #expect(anchor.key == WorkspaceKey(rawValue: "ws-key-1"))
        #expect(anchor.pane.handle == PaneID(rawValue: 7))
    }

    /// A workspace with no pane, or a machine whose workspaces did not load in time, names the
    /// workspace, its machine and the command that makes a new one.
    @Test func aWorkspaceThatIsNotReadySaysSoAndGivesTheNextCommand() {
        for message in [CloudStrings.machineWorkspaceHasNoPane("vm-a", "ws_one"), CloudStrings.machineWorkspacesNotLoaded("vm-a", "ws_one")] {
            #expect(message.contains("`ws_one`"))
            #expect(message.contains("`vm-a`"))
            #expect(message.contains("cmux cloud new-terminal-on-machine --target machine:vm-a"))
        }
    }

    @Test func aTerminalAnswerCarriesTheSurfaceAndTheTerminalWhenKnown() {
        #expect(CloudHandlers.terminalFields(SurfaceID(rawValue: 42), terminal: nil) == ["surface_id": .string("42")])
        let both = CloudHandlers.terminalFields(SurfaceID(rawValue: 42), terminal: TerminalID(rawValue: "term_1"))
        #expect(both == ["surface_id": .string("42"), "terminal_id": .string("term_1")])
    }

    @Test func aPendingAnswerNamesTheMachine() {
        let f = CloudCLITargetTests.fixture()
        #expect(CloudHandlers.terminalPending(f.session)["machine_id"] == .string(f.session.machineID))
    }

    // MARK: Catalog

    @Test func sshAndNewTerminalAnswerTheirCaller() throws {
        for id: ActionID in ["cloudSSH", "cloudNewTerminal"] {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == id })
            #expect(descriptor.waitsForResult, "\(id) answers its ids")
        }
    }

    /// The title says it makes a workspace; the CLI name stays, so no script breaks.
    @Test func newTerminalTakesAnOptionalWorkspaceAndKeepsItsCLIName() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "cloudNewTerminal" })
        #expect(descriptor.cliName == "cloud new-terminal-on-machine")
        #expect(descriptor.title == "New Terminal Workspace on Machine")
        let workspace = try #require(descriptor.arguments.first { $0.name == "workspace" })
        #expect(!workspace.isRequired)
        #expect(workspace.kind == .string, "a Cloud machine's workspace, not one of this Mac's")
    }
}
