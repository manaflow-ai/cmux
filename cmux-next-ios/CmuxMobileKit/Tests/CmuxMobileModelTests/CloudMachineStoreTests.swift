import Foundation
import Testing
@testable import CmuxMobileModel

/// Cloud machines beside the Macs (plans/cmux-next/cloud-ios.md §3.1): their workspaces are the
/// store's like a Mac's, new workspaces can go to a running one, and they never join a team's
/// Macs (Settings → Devices, pairing, presence).
@MainActor @Suite struct CloudMachineStoreTests {
    let vm = "vm_aaaaaaaaaaaaaaaaaaaa"

    func store() -> AppStore {
        let team = Team(id: "t", name: "Personal", macs: [MacDevice(id: "mac-1", name: "Studio", isOnline: true)])
        let store = AppStore(teams: [team], activeTeamID: "t", workspaces: [
            Workspace(id: "w-mac", macID: "mac-1", title: "cmux", directory: "~", tabs: [], lastActivityAt: .now),
            Workspace(id: "w-cloud", macID: vm, title: "evals", directory: "~", tabs: [], lastActivityAt: .now),
        ], feed: [], tabMemory: .inMemory())
        store.cloudMachines = [MacDevice(cloudMachine: vm, name: "Build box", state: CloudMachineState(status: .running))]
        return store
    }

    @Test func cloudMachinesStayOutOfTheTeamsMacs() {
        let store = store()
        #expect(store.activeTeam?.macs.map(\.id) == ["mac-1"])
        #expect(store.workspaceMachines.map(\.id) == ["mac-1", vm])
        #expect(store.machine(id: vm)?.isCloud == true)
        #expect(store.isCloudMachine(vm) && !store.isCloudMachine("mac-1"))
    }

    @Test func cloudWorkspacesAreActiveWorkspaces() {
        let store = store()
        #expect(Set(store.activeWorkspaces.map(\.id)) == ["w-mac", "w-cloud"])
        store.cloudMachines = []
        #expect(store.activeWorkspaces.map(\.id) == ["w-mac"])
    }

    @Test func aRunningCloudMachineTakesNewWorkspaces() {
        let store = store()
        let backend = ScriptedBackend()
        backend.creatable = ["mac-1", vm]
        let creator = WorkspaceCreator(store: store, backend: backend,
                                       defaults: UserDefaults(suiteName: "cloud-store-\(UUID().uuidString)") ?? .standard)
        #expect(creator.availableMacs.map(\.id) == ["mac-1", vm])
        #expect(creator.create(macID: vm)?.macID == vm)
        // Paused: no new workspaces, no rename or close (its rows are last known).
        store.cloudMachines = [MacDevice(cloudMachine: vm, name: "Build box", state: CloudMachineState(status: .paused))]
        #expect(creator.availableMacs.map(\.id) == ["mac-1"])
        #expect(creator.rights(onMac: vm) == .none)
    }

    @Test func aCloudMachineIsOnlineOnlyWhileRunning() {
        for status in [CloudMachineState.Status.provisioning, .starting, .pausing, .paused, .deleting, .failed] {
            #expect(!MacDevice(cloudMachine: vm, name: "x", state: CloudMachineState(status: status)).isOnline)
        }
        #expect(MacDevice(cloudMachine: vm, name: "x", state: CloudMachineState(status: .running)).isOnline)
    }

    /// A Mac saved before Cloud machines decodes as a Mac.
    @Test func aSavedMacDecodesWithoutCloud() throws {
        let data = Data(#"{"id":"m","name":"Studio","isOnline":true}"#.utf8)
        let mac = try JSONDecoder().decode(MacDevice.self, from: data)
        #expect(!mac.isCloud)
    }

    /// The filter remembers a Cloud machine scope while it is listed.
    @Test func theFilterResolvesACloudScope() {
        let store = store()
        let defaults = UserDefaults(suiteName: "cloud-filter-\(UUID().uuidString)") ?? .standard
        let filter = MacFilter(defaults: defaults)
        filter.select(.mac(vm), in: "t")
        #expect(filter.scope(in: store.activeTeam, cloudMachines: store.cloudMachines) == .mac(vm))
        #expect(filter.scope(in: store.activeTeam) == .all)
    }
}
