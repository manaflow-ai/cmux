import AppKit
@testable import CmuxNextApp
import CmuxNextCloud
@testable import CmuxNextDaemon
import CmuxNextRemote
import Foundation
import Testing

/// Review of #28358 (P-AUSTIN B7b): a saved Cloud workspace whose machine this run has no daemon
/// for is gone only when the signed-in account's own machine list loaded without its machine.
/// These run `WindowManager.isDead` itself with a given account state (`WindowManager.cloudList`),
/// since a test cannot sign in.
@MainActor @Suite(.serialized)
struct CloudWorkspaceAccountListTests {
    static let workspace = "ws-account-list"

    /// Services with this Mac's tree loaded and `workspace` saved on Cloud machine `machine`.
    static func services(savedOn machine: String, list: CloudMachineListFacts) -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.machines.local.store.apply(snapshot: DaemonTree(registryID: "s-local"))
        services.windows.cloudList = { _ in list }
        var record = WindowRecord(id: "w1", workspaceKey: WorkspaceKey(rawValue: workspace),
                                  workspaceKeys: [WorkspaceKey(rawValue: workspace)], machine: machine)
        record.workspaceMachines = [workspace: machine]
        services.windows.rememberMachines(of: WindowStateDocument(windows: [record]))
        return services
    }

    static let signedInWithCurrentList = CloudMachineListFacts(isSignedIn: true, isRestoring: false,
                                                               hasLoadedCurrentMachines: true)

    /// Finding 4: a machine deleted from the account (the signed-in account's loaded list does not
    /// have it, so the registry has no session for it) takes its workspace out of the saved window;
    /// the window's workspace on a machine the list still has stays, with its machine.
    @Test func aMachineDeletedFromTheAccountTakesItsWorkspaceOutOfTheSavedWindow() {
        let services = Self.services(savedOn: "vm-deleted", list: Self.signedInWithCurrentList)
        let windows = services.windows
        #expect(windows.isDead(Self.workspace), "the account's loaded list does not have its machine: it left the account")
        // The window's other workspace is on a machine the list has (paused, so it has no tree yet).
        let kept = "ws-account-list-kept"
        _ = CloudWorkspaceRestoreTests.pausedMachine(services, id: "vm-kept")
        var record = WindowRecord(id: "w1", workspaceKey: WorkspaceKey(rawValue: kept),
                                  workspaceKeys: [WorkspaceKey(rawValue: kept), WorkspaceKey(rawValue: Self.workspace)])
        record.workspaceMachines = [kept: "vm-kept", Self.workspace: "vm-deleted"]
        windows.rememberMachines(of: WindowStateDocument(windows: [record]))
        #expect(!windows.isDead(kept), "a listed machine's workspace waits for its machine")
        var document = WindowStateDocument(windows: [record])
        document.prune(liveWorkspaces: Set([WorkspaceKey(rawValue: kept), WorkspaceKey(rawValue: Self.workspace)]
            .filter { !windows.isDead($0.rawValue) }))
        #expect(document.windows.first?.workspaceKeys == [WorkspaceKey(rawValue: kept)])
        #expect(document.windows.first?.workspaceMachines == [kept: "vm-kept"])
    }

    /// Finding 4: the same account state with the machine listed (paused, so it has no tree yet)
    /// keeps the workspace: only "not listed" and "the list loaded" together mean gone.
    @Test func aListedMachineKeepsItsWorkspaceWithTheSameAccountList() {
        let services = Self.services(savedOn: "vm-listed", list: Self.signedInWithCurrentList)
        _ = CloudWorkspaceRestoreTests.pausedMachine(services, id: "vm-listed")
        #expect(!services.windows.isDead(Self.workspace), "a listed machine that has not connected is not gone")
    }

    /// Finding 1: during a team switch the user stays signed in and the store still holds the
    /// previous team's list until the new team's arrives. A workspace on a machine of the new team
    /// is not in that old list; it must wait for the new team's list, not be pruned.
    @Test func aTeamSwitchDoesNotPruneTheNewTeamsWorkspaceFromTheOldTeamsList() {
        let previousTeamsList = CloudMachineListFacts(isSignedIn: true, isRestoring: false,
                                                      hasLoadedCurrentMachines: false)
        let services = Self.services(savedOn: "vm-new-team", list: previousTeamsList)
        #expect(!services.windows.isDead(Self.workspace),
                "the store's list is the previous team's: it says nothing about the new team's machines")
    }

    /// Review of #28393, finding 2: a saved workspace this run never saw on any machine is gone only
    /// once every machine that could hold it has loaded. During a team switch the store still holds the
    /// previous team's list, so the new team's machines have not been listed yet: it must wait.
    @Test func aNeverSeenWorkspaceWaitsForTheNewTeamsList() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.machines.local.store.apply(snapshot: DaemonTree(registryID: "s-local"))
        services.windows.cloudList = { _ in
            CloudMachineListFacts(isSignedIn: true, isRestoring: false, hasLoadedCurrentMachines: false)
        }
        #expect(!services.windows.isDead("ws-never-seen"),
                "the store's list is the previous team's: the new team's machines may still hold the workspace")
        services.windows.cloudList = { _ in Self.signedInWithCurrentList }
        #expect(services.windows.isDead("ws-never-seen"), "the new team's list loaded without it, and this Mac's tree has none")
    }

    /// Review of #28393 at 9f937401f6a: the rule that only the current account's list counts lives in
    /// `CloudMachineListFacts`, built from the store's raw list state. After a team switch the store still
    /// holds the previous team's list: it must not say the new team's machine left, nor that the lists
    /// settled; the new team's own list does.
    @Test func thePreviousTeamsStoredListIsNotTheCurrentAccountsList() {
        let oldTeam: [String?] = ["user-cloudlist", "team-old"]
        let newTeam: [String?] = ["user-cloudlist", "team-new"]
        let stale = CloudMachineListFacts(isSignedIn: true, isRestoring: false, hasLoadedMachines: true,
                                          loadedFor: oldTeam, account: newTeam)
        #expect(!stale.hasLoadedCurrentMachines, "the stored list is the previous team's")
        #expect(!stale.machineLeft(listed: false), "a machine the old team's list lacks did not leave the new team")
        #expect(!stale.settled { true }, "the new team's list has not loaded")
        let services = Self.services(savedOn: "vm-new-team", list: stale)
        #expect(!services.windows.isDead(Self.workspace), "the new team's workspace waits for the new team's list")

        let current = CloudMachineListFacts(isSignedIn: true, isRestoring: false, hasLoadedMachines: true,
                                            loadedFor: newTeam, account: newTeam)
        #expect(current.machineLeft(listed: false), "the new team's own list without the machine: it left")
        #expect(current.settled { true })
        let none = CloudMachineListFacts(isSignedIn: true, isRestoring: false, hasLoadedMachines: false,
                                         loadedFor: nil, account: newTeam)
        #expect(!none.hasLoadedCurrentMachines, "no list has loaded")
    }

    /// Finding 3: the ids the app gives SSH machines and paired servers are never Cloud ids, read
    /// from the types that make them, so a change of their id form cannot make them Cloud machines.
    @Test func sshAndServerMachineIDsAreNeverCloudIDs() throws {
        let ssh = try SSHHost(destination: SSHDestination(parsing: "me@cloud-list-box"))
        let server = try ServerReach(hostID: "host_cloudlist01", installID: "inst_cloudlist01", name: "Mini",
                                     route: .overlay(linkSocket: "/tmp/cmux-cloud-list-link.sock"))
        #expect(!MachineRegistry.isCloudMachineID(ssh.machineID))
        #expect(!MachineRegistry.isCloudMachineID(server.machineID))
        #expect(MachineRegistry.isCloudMachineID("vm_0123456789"))
    }
}
