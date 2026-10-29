import AppKit
@testable import CmuxNextApp
import CmuxNextCloud
@testable import CmuxNextDaemon
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

        // A machine that left the account takes its workspaces with it.
        _ = services.machines.remove(machine.machineID)
        #expect(windows.isDead(Self.cloudWorkspace))
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
        let link = CloudMachineLink(machineID: id, api: api, hub: hub, paths: paths, binary: binary, deviceName: "cn-restore-test",
                                    mainWork: services.mainWork)
        let session = CloudMachineSession(machine: CloudMachine(id: id, status: .paused, displayName: "Restore VM"), link: link,
                                          mainWork: services.mainWork, deadlines: services.mainDeadlines, appEvents: services.appEvents,
                                          work: services.work)
        services.machines.add(session)
        return session
    }
}
