import AppKit
@testable import CmuxNextApp
import CmuxNextCloud
@testable import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import Testing

/// A Cloud workspace comes back to its window after a relaunch (#25582). Each window record keeps
/// the machine of every workspace it lists that is not on this Mac (`workspace_machines`), and the
/// restore seeds `WindowManager.seenMachine` from it: a workspace on a Cloud machine that cmux
/// Cloud's idle auto-pause parked while the app was quit (so its tree never loads at launch) is
/// not "gone" and stays in its window, where it shows again, with its layout, once the machine
/// connects. Before, the launch had seen no machine for it, read it as dead once this Mac's tree
/// and the Cloud list loaded, and dropped it from the window and from the saved records.
@MainActor @Suite(.serialized)
struct CloudWorkspaceRestoreTests {
    static let cloudWorkspace = "ws-cloud-restore"

    // MARK: The record

    @Test func aRecordKeepsTheMachineOfEachRemoteWorkspaceAndOlderRecordsHaveNone() throws {
        var record = WindowRecord(id: "w1", workspaceKey: WorkspaceKey(rawValue: "ws-a"),
                                  workspaceKeys: [WorkspaceKey(rawValue: "ws-a"), WorkspaceKey(rawValue: Self.cloudWorkspace)])
        record.workspaceMachines = [Self.cloudWorkspace: "vm-1"]
        let decoded = try JSONDecoder().decode(WindowRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.workspaceMachines == [Self.cloudWorkspace: "vm-1"])
        let older = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w2","workspace_key":"ws-b"}"#.utf8))
        #expect(older.workspaceMachines.isEmpty, "a record from an older build has no workspace machines")
    }

    @Test func aRecordsOwnWorkspaceMachinesWinOverTheMachineOfItsShownWorkspace() {
        var record = WindowRecord(id: "w1", workspaceKey: WorkspaceKey(rawValue: Self.cloudWorkspace), machine: "vm-shown")
        record.workspaceMachines = [Self.cloudWorkspace: "vm-1"]
        let older = WindowRecord(id: "w2", workspaceKey: WorkspaceKey(rawValue: "ws-older"), machine: "vm-2")
        #expect(WindowStateDocument(windows: [record, older]).workspaceMachines == [Self.cloudWorkspace: "vm-1", "ws-older": "vm-2"])
    }

    @Test func pruneDropsTheMachineOfAPrunedWorkspace() {
        var record = WindowRecord(id: "w1", workspaceKey: WorkspaceKey(rawValue: "ws-a"),
                                  workspaceKeys: [WorkspaceKey(rawValue: "ws-a"), WorkspaceKey(rawValue: Self.cloudWorkspace)])
        record.workspaceMachines = [Self.cloudWorkspace: "vm-1"]
        var document = WindowStateDocument(windows: [record])
        document.prune(liveWorkspaces: [WorkspaceKey(rawValue: "ws-a"), WorkspaceKey(rawValue: Self.cloudWorkspace)])
        #expect(document.windows.first?.workspaceMachines == [Self.cloudWorkspace: "vm-1"])
        document.prune(liveWorkspaces: [WorkspaceKey(rawValue: "ws-a")])
        #expect(document.windows.first?.workspaceKeys == [WorkspaceKey(rawValue: "ws-a")])
        #expect(document.windows.first?.workspaceMachines.isEmpty == true)
    }

    @Test func aSavedWindowNamesTheMachinesOfItsRemoteWorkspacesOnly() throws {
        var registry = WindowRegistry()
        registry.openWindow(id: "w1", workspaceIDs: ["ws-local", Self.cloudWorkspace])
        let record = try #require(registry.record("w1", state: nil, order: 0, machines: [
            "ws-local": MachineRegistry.localID, Self.cloudWorkspace: "vm-1", "ws-elsewhere": "vm-2",
        ]))
        #expect(record.workspaceMachines == [Self.cloudWorkspace: "vm-1"],
                "only the window's own workspaces that are not on this Mac")
    }

    // MARK: The restore

    @Test func aWorkspaceOnAPausedCloudMachineStaysInItsWindowAfterARelaunch() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        try #require(!services.cloud.isSignedIn && !services.cloud.auth.isRestoring, "the Cloud list must not hold the decision")
        services.machines.local.store.apply(snapshot: DaemonTree(registryID: "s-local"))
        try #require(services.machines.local.store.isLoaded)
        let machine = Self.pausedMachine(services, id: "vm-restore")
        let windows = services.windows

        // Nothing seen yet: the launch reads the saved workspace as gone.
        #expect(windows.isDead(Self.cloudWorkspace))

        var record = WindowRecord(id: "w1", workspaceKey: WorkspaceKey(rawValue: Self.cloudWorkspace),
                                  workspaceKeys: [WorkspaceKey(rawValue: Self.cloudWorkspace)], machine: machine.machineID)
        record.workspaceMachines = [Self.cloudWorkspace: machine.machineID]
        windows.rememberMachines(of: WindowStateDocument(windows: [record]))
        #expect(!windows.isDead(Self.cloudWorkspace), "its machine is paused, not gone: the workspace waits for it")

        // Signed out, a machine missing from the registry is not connected, not gone (P-AUSTIN B7b):
        // the workspace stays. A machine that left the account (a loaded list of the signed-in
        // account without it) takes its workspaces with it: `aMachineLeftOnlyWhenTheAccountListSaysSo`.
        _ = services.machines.remove(machine.machineID)
        #expect(!windows.isDead(Self.cloudWorkspace), "signed out, a Cloud workspace is pruned for its connection state")
    }

    /// P-AUSTIN B7b: Cloud VM workspaces stay in the window record, shown as disconnected, while the
    /// Cloud is not connected (signed out, Cloud turned off, its list not loaded) at save or restore
    /// time. They are never pruned because of connection state; only a machine that left the account
    /// takes its workspaces with it.
    @Test func aMachineLeftOnlyWhenTheAccountListSaysSo() {
        let loaded = CloudMachineListFacts(isSignedIn: true, isRestoring: false, hasLoadedCurrentMachines: true)
        let notLoaded = CloudMachineListFacts(isSignedIn: true, isRestoring: false, hasLoadedCurrentMachines: false)
        let signedOut = CloudMachineListFacts(isSignedIn: false, isRestoring: false, hasLoadedCurrentMachines: false)
        #expect(!notLoaded.machineLeft(listed: false) && !signedOut.machineLeft(listed: false),
                "signed out or the list not loaded: the machine is only not connected")
        #expect(!loaded.machineLeft(listed: true), "listed with its feature turned off: not connected, not gone")
        #expect(!notLoaded.machineLeft(listed: true))
        #expect(loaded.machineLeft(listed: false), "the signed-in account's loaded list does not have it: it left the account")
    }

    @Test func aCloudWorkspaceSavedWhileSignedOutStaysAndWaitsForItsMachine() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        try #require(!services.cloud.isSignedIn && !services.cloud.auth.isRestoring, "the test runs signed out")
        services.machines.local.store.apply(snapshot: DaemonTree(registryID: "s-local"))
        let windows = services.windows
        var record = WindowRecord(id: "w1", workspaceKey: WorkspaceKey(rawValue: Self.cloudWorkspace),
                                  workspaceKeys: [WorkspaceKey(rawValue: Self.cloudWorkspace)], machine: "vm-signed-out")
        record.workspaceMachines = [Self.cloudWorkspace: "vm-signed-out"]
        windows.rememberMachines(of: WindowStateDocument(windows: [record]))
        // Signed out: no Cloud machine is in the registry at all (sign-out drops them all).
        #expect(!windows.isDead(Self.cloudWorkspace), "a Cloud workspace is dropped because the Cloud is not connected")
        var document = WindowStateDocument(windows: [record])
        let live = Set([WorkspaceKey(rawValue: Self.cloudWorkspace)].filter { !windows.isDead($0.rawValue) })
        document.prune(liveWorkspaces: live)
        #expect(document.windows.first?.workspaceKeys == [WorkspaceKey(rawValue: Self.cloudWorkspace)],
                "the saved window record lost its Cloud workspace")
        #expect(document.windows.first?.workspaceMachines == [Self.cloudWorkspace: "vm-signed-out"])
        // The Cloud connects again: its machine is back in the registry and the workspace waits for it.
        _ = Self.pausedMachine(services, id: "vm-signed-out")
        #expect(!windows.isDead(Self.cloudWorkspace))
    }

    @Test func theShownWorkspaceOfAnOlderRecordWaitsForItsMachineToo() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.machines.local.store.apply(snapshot: DaemonTree(registryID: "s-local"))
        let machine = Self.pausedMachine(services, id: "vm-older")
        let older = try JSONDecoder().decode(WindowRecord.self, from: Data(
            #"{"id":"w1","workspace_key":"\#(Self.cloudWorkspace)","machine":"\#(machine.machineID)"}"#.utf8))
        services.windows.rememberMachines(of: WindowStateDocument(windows: [older]))
        #expect(services.windows.seenMachine[Self.cloudWorkspace] == machine.machineID)
        #expect(!services.windows.isDead(Self.cloudWorkspace))
    }

    /// A Cloud machine this run has not loaded (paused by the idle auto-pause: never connected).
    static func pausedMachine(_ services: AppServices, id: String) -> CloudMachineSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-cloud-restore-\(UUID().uuidString.prefix(8))")
        let paths = CloudPaths(root: root), binary = URL(fileURLWithPath: "/usr/bin/false"), api = services.cloud.api
        let hub = CloudTunnelHub(api: api, paths: paths, binary: binary, deviceName: "cn-restore-test")
        let link = CloudMachineLink(machineID: id, api: api, hub: hub, paths: paths, binary: binary, deviceName: "cn-restore-test")
        let session = CloudMachineSession(machine: CloudMachine(id: id, status: .paused, displayName: "Restore VM"), link: link, mainWork: services.mainWork)
        services.machines.add(session)
        return session
    }

    /// Review of #28358: the account-list rule is for Cloud machines only. A forgotten SSH machine
    /// or server is not in any Cloud list, so while signed out of Cloud its workspaces must still
    /// be gone, as before B7b.
    @Test func aForgottenSSHOrServerMachinesWorkspaceIsStillGoneWhileSignedOutOfCloud() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        try #require(!services.cloud.isSignedIn && !services.cloud.auth.isRestoring, "the test runs signed out")
        services.machines.local.store.apply(snapshot: DaemonTree(registryID: "s-local"))
        let windows = services.windows
        var record = WindowRecord(id: "w1", workspaceKey: WorkspaceKey(rawValue: "ws-ssh"),
                                  workspaceKeys: [WorkspaceKey(rawValue: "ws-ssh"), WorkspaceKey(rawValue: "ws-server")])
        record.workspaceMachines = ["ws-ssh": "ssh-0a1b2c3d4e5f", "ws-server": "server-host-1"]
        windows.rememberMachines(of: WindowStateDocument(windows: [record]))
        #expect(windows.isDead("ws-ssh"), "a forgotten SSH machine's workspace is kept while signed out of Cloud")
        #expect(windows.isDead("ws-server"), "a forgotten server's workspace is kept while signed out of Cloud")
    }

    @Test func onlyCloudMachineIDsAreCloud() {
        #expect(MachineRegistry.isCloudMachineID("vm-restore"))
        #expect(!MachineRegistry.isCloudMachineID("ssh-0a1b2c3d4e5f"))
        #expect(!MachineRegistry.isCloudMachineID("server-host-1"))
        #expect(!MachineRegistry.isCloudMachineID(MachineRegistry.localID))
    }
}
