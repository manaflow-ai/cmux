import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// Reconnect Workspace, Disconnect Workspace, Copy SSH Error and Disconnect
/// SSH Tab (`SSHTargetHandlers`) act on the SSH machine their workspace or
/// tab runs on. They are no longer greyed out with a missing daemon
/// capability; a workspace or tab of this Mac leaves them out of its menu,
/// and a run on one is refused with the reason.
@MainActor @Suite(.serialized)
struct SSHTargetActionsTests {
    static let workspaceActions: [ActionID] = ["reconnectWorkspace", "disconnectWorkspace", "copyWorkspaceSSHError"]
    static let tabAction: ActionID = "disconnectRemoteTab"

    static func fixture() -> (services: AppServices, workspace: String, tab: TabModel) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, kind: .pty, title: "zsh", url: "")])])
        services.machines.local.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "local", screens: [screen])]))
        let workspace = services.machines.local.store.workspaces[0]
        return (services, workspace.id, workspace.screens[0].panes[0].tabs[0])
    }

    @Test func theRowsAreNoLongerGreyedOutForAMissingCapability() {
        let services = Self.fixture().services
        for id in Self.workspaceActions + [Self.tabAction] {
            // Only the SSH client's own reason (no bundled cmux-tui) may grey them out.
            #expect(services.registry.unavailableReason(for: id) == services.ssh.unavailableReason, "\(id)")
        }
    }

    @Test func aLocalWorkspaceAndTabLeaveTheRowsOutOfTheirMenus() {
        let f = Self.fixture()
        let workspaceRows = CopyAgentIdentifierTests.runs(CopyAgentIdentifierTests.workspaceMenu(f.workspace, f.services))
        for id in Self.workspaceActions { #expect(!workspaceRows.contains(id), "\(id) on a workspace of this Mac") }
        #expect(!CopyAgentIdentifierTests.runs(CopyAgentIdentifierTests.tabMenu(f.tab, f.services)).contains(Self.tabAction))
    }

    @Test func aRunOnALocalWorkspaceOrTabIsRefusedWithTheReason() {
        let f = Self.fixture()
        let registry = f.services.registry
        // A host without the bundled cmux-tui (a test host) greys every SSH row out for that first.
        if let noClient = f.services.ssh.unavailableReason {
            for id in Self.workspaceActions + [Self.tabAction] { #expect(registry.unavailableReason(for: id) == noClient, "\(id)") }
            return
        }
        for id in Self.workspaceActions {
            let refusal = registry.capturingRefusal {
                _ = registry.perform(id, invocation: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: f.workspace)))
            }
            #expect(refusal == RemoteStrings.workspaceNotOnSSHMachine, "\(id)")
        }
        let refusal = registry.capturingRefusal {
            _ = registry.perform(Self.tabAction, invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: f.tab.id)))
        }
        #expect(refusal == RemoteStrings.tabNotOnSSHMachine)
    }
}
