import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextRemote
import Foundation
import Testing

/// Reconnect Workspace, Disconnect Workspace, Copy SSH Error and Disconnect SSH Tab act on the SSH
/// machine that a workspace or a tab runs on: they run the machine's own Reconnect, Disconnect and
/// Copy SSH Error (`remote.reconnect`, `remote.disconnect`, `remote.copyError`), so the workspace
/// row's menu, the tab's menu, the palette, the CLI and MCP all go through one path. A workspace or
/// tab on this Mac is refused with a reason, never a silent no-op.
@MainActor @Suite(.serialized)
struct RemoteWorkspaceActionsTests {
    static let ids: [ActionID] = ["reconnectWorkspace", "disconnectWorkspace", "copyWorkspaceSSHError", "disconnectRemoteTab"]

    static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        return services
    }

    /// One tree with one workspace holding one terminal tab.
    static func tree(workspace: WorkspaceHandle, screen: ScreenID, pane: PaneID, surface: SurfaceID) -> DaemonTree {
        let paneSnapshot = PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: surface, kind: .pty)])
        let screenSnapshot = ScreenSnapshot(id: screen, layout: .leaf(pane), panes: [paneSnapshot])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: workspace, key: nil, name: "remote", screens: [screenSnapshot])])
    }

    /// An SSH machine whose daemon tree holds one workspace with one terminal tab. Its daemon is
    /// blocked, so a reconnect only opens the gate and never dials ssh from the test.
    static func sshMachine(_ services: AppServices) throws -> (session: SSHMachineSession, workspace: WorkspaceModel, tab: TabModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-remote-ws-\(UUID().uuidString.prefix(8))")
        let host = try SSHHost(destination: SSHDestination(parsing: "me@remote-box"))
        let session = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"), paths: SSHPaths(root: root),
                                        environment: { [:] })
        session.daemon.policyBlock.set(true)
        services.machines.add(session)
        session.daemon.store.apply(snapshot: tree(workspace: 9101, screen: 9103, pane: 9104, surface: 9102))
        let workspace = try #require(session.daemon.store.workspaces.first)
        let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
        return (session, workspace, tab)
    }

    /// A workspace on this Mac with one terminal tab.
    static func localWorkspace(_ services: AppServices) throws -> (workspace: WorkspaceModel, tab: TabModel) {
        services.machines.local.store.apply(snapshot: tree(workspace: 9201, screen: 9203, pane: 9204, surface: 9202))
        let workspace = try #require(services.machines.local.store.workspaces.first)
        let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
        return (workspace, tab)
    }

    static func run(_ id: ActionID, _ kind: ActionTargetKind, _ target: String, in services: AppServices) -> String? {
        services.registry.capturingRefusal {
            _ = services.registry.perform(id, invocation: ActionInvocation(target: ActionTargetRef(kind: kind, id: target)))
        }
    }

    @Test func theRemoteWorkspaceAndSSHTabActionsAreAvailable() {
        let services = Self.services()
        for id in Self.ids {
            #expect(services.registry.unavailableReason(for: id) == nil, "\(id.rawValue) is greyed out")
        }
    }

    @Test func disconnectWorkspaceDisconnectsItsMachineAndReconnectConnectsItAgain() throws {
        let services = Self.services()
        let (session, workspace, _) = try Self.sshMachine(services)
        session.autoConnect = true
        #expect(Self.run("disconnectWorkspace", .workspace, workspace.id, in: services) == nil)
        #expect(session.autoConnect == false, "a person's disconnect keeps the machine offline at the next launch")
        #expect(session.linkStatus == .offline)

        #expect(Self.run("reconnectWorkspace", .workspace, workspace.id, in: services) == nil)
        #expect(session.autoConnect, "reconnect sets the machine to connect again")
        #expect(session.linkStatus == .connecting)
    }

    @Test func copySSHErrorCopiesTheMachinesLastError() throws {
        let services = Self.services()
        let (session, workspace, _) = try Self.sshMachine(services)
        #expect(Self.run("copyWorkspaceSSHError", .workspace, workspace.id, in: services) != nil, "no error yet: refused with a reason")

        let error = "Permission denied (publickey) \(UUID().uuidString)"
        session.lastError = error
        #expect(Self.run("copyWorkspaceSSHError", .workspace, workspace.id, in: services) == nil)
        #expect(NSPasteboard.general.string(forType: .string) == error)
    }

    @Test func disconnectSSHTabDisconnectsTheMachineItsTerminalRunsOn() throws {
        let services = Self.services()
        let (session, _, tab) = try Self.sshMachine(services)
        session.autoConnect = true
        #expect(Self.run("disconnectRemoteTab", .tab, tab.id, in: services) == nil)
        #expect(session.autoConnect == false)
        #expect(session.linkStatus == .offline)
    }

    @Test func aWorkspaceOrTabOnThisMacIsRefusedWithAReason() throws {
        let services = Self.services()
        let (session, _, _) = try Self.sshMachine(services)
        session.autoConnect = true
        let (workspace, tab) = try Self.localWorkspace(services)
        for id: ActionID in ["reconnectWorkspace", "disconnectWorkspace", "copyWorkspaceSSHError"] {
            let reason = Self.run(id, .workspace, workspace.id, in: services)
            #expect(reason != nil && reason != "", "\(id.rawValue) on this Mac's workspace")
        }
        #expect(Self.run("disconnectRemoteTab", .tab, tab.id, in: services) != nil)
        #expect(session.autoConnect, "another machine is never disconnected in its place")
    }
}
