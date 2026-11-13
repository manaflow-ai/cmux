#if DEBUG && os(iOS)
import CmuxMobileChief
import CmuxMobileDesign
import CmuxMobileModel
import CmuxMobileWorkspaces
import Observation
import SwiftUI

/// Cloud workspaces in the DEBUG gallery (`-cmux-mobile-recovery-gallery cloudworkspaces` and
/// `cloudmachines`): the production Workspaces list and Cloud Machines page over a fixed store
/// with one Mac and a Cloud machine in every state (running with workspaces, paused with a
/// folded workspace, waking up, failed, running with none, and one New Cloud Workspace being
/// made). Its actions change only the fixture.
@MainActor
final class CloudWorkspacesGallery {
    let store: AppStore
    let creator: WorkspaceCreator
    let actions: GalleryCloudActions

    static let mac = "mac_gallery_studio"
    static let running = "vm_gallery0000000000001"
    static let paused = "vm_gallery0000000000002"
    static let waking = "vm_gallery0000000000003"
    static let failed = "vm_gallery0000000000004"
    static let empty = "vm_gallery0000000000005"
    static let pending = "vm_gallery0000000000006"

    init(now: Date = .now) {
        let ago = { (seconds: TimeInterval) in now.addingTimeInterval(-seconds) }
        func workspace(_ id: String, _ macID: String, _ title: String, _ branch: String, _ seconds: TimeInterval) -> Workspace {
            Workspace(id: id, macID: macID, title: title, directory: "~/code/\(title)", branch: branch,
                      tabs: [WorkspaceTab(id: "\(id)-t1", kind: .terminal, title: "zsh", subtitle: "~/code/\(title)")],
                      lastActivityAt: ago(seconds))
        }
        let team = Team(id: "gallery-team", name: "Personal", macs: [MacDevice(id: Self.mac, name: "Aziz's Mac Studio", isOnline: true)])
        store = AppStore(teams: [team], activeTeamID: team.id, workspaces: [
            workspace("ws-mac-1", Self.mac, "cmux", "feat-cmux-next", 60),
            workspace("ws-cloud-1", Self.running, "evals", "main", 120),
            workspace("ws-cloud-2", Self.running, "api", "fix-pricing", 900),
            workspace("ws-paused-1", Self.paused, "nightly", "main", 86_400),
        ], feed: [], tabMemory: .inMemory())
        store.cloudMachines = [
            MacDevice(cloudMachine: Self.running, name: "Build box", state: CloudMachineState(status: .running)),
            MacDevice(cloudMachine: Self.paused, name: "Nightly evals", state: CloudMachineState(status: .paused, note: "Paused after it sat idle.")),
            MacDevice(cloudMachine: Self.waking, name: "Repro sandbox", state: CloudMachineState(status: .starting)),
            MacDevice(cloudMachine: Self.failed, name: "GPU box", state: CloudMachineState(status: .failed, note: "It didn't start.")),
            MacDevice(cloudMachine: Self.empty, name: "Scratch", state: CloudMachineState(status: .running)),
            MacDevice(cloudMachine: Self.pending, name: "Cloud Machine", state: CloudMachineState(status: .provisioning, pendingWorkspace: true)),
        ]
        creator = WorkspaceCreator(store: store, backend: MockWorkspaceCreationBackend(), defaults: UserDefaults(suiteName: "cmux-gallery-cloud") ?? .standard)
        actions = GalleryCloudActions(store: store)
        creator.cloud = actions
    }

    /// The Workspaces list as the Workspaces tab shows it.
    var list: some View {
        NavigationStack {
            WorkspacesList(store: store, creator: creator) { _ in }
                .navigationBarTitleDisplayMode(.inline)
                .background(CmuxMobileTheme.standard.colors.bg.color.ignoresSafeArea())
        }
    }

    /// The machine page's Workspaces section over the same store; a workspace opens as a route
    /// on `path`, as the app's Settings stack does.
    func machineWorkspaces(path: Binding<[Workspace]>) -> CloudMachineWorkspaces {
        let store = store, creator = creator
        return CloudMachineWorkspaces(
            state: { id in
                id == Self.waking ? .loading : .loaded(store.workspaces.filter { $0.macID == id })
            },
            canCreate: { id in creator.availableMacs.contains { $0.id == id } },
            create: { creator.create(start: .terminal, macID: $0) },
            page: { workspace in AnyView(WorkspaceScreen(store: store, workspaceID: workspace.id, creator: creator)) },
            open: { path.wrappedValue.append($0) })
    }

    /// The Cloud Machines page with its machines' workspaces pushed on its own path.
    struct MachinesPage: View {
        let gallery: CloudWorkspacesGallery
        @State private var path: [Workspace] = []

        var body: some View {
            NavigationStack(path: $path) {
                CloudMachinesScreen(model: .gallery(), workspaces: gallery.machineWorkspaces(path: $path))
                    .navigationDestination(for: Workspace.self) { workspace in
                        WorkspaceScreen(store: gallery.store, workspaceID: workspace.id, creator: gallery.creator)
                    }
            }
        }
    }
}

/// The gallery's Cloud actions: Start wakes the machine in the fixture; New Cloud Workspace
/// adds a pending machine line.
@MainActor
@Observable
final class GalleryCloudActions: CloudWorkspaceActions {
    @ObservationIgnored let store: AppStore
    var canCreateMachine = true

    init(store: AppStore) { self.store = store }

    func start(machineID: String) {
        guard let index = store.cloudMachines.firstIndex(where: { $0.id == machineID }) else { return }
        store.cloudMachines[index].cloud = CloudMachineState(status: .starting)
        store.cloudMachines[index].isOnline = false
    }

    func newCloudWorkspace(open: @escaping @MainActor (Workspace) -> Void) {
        let id = "vm_gallerynew\(store.cloudMachines.count)"
        store.cloudMachines.append(MacDevice(cloudMachine: id, name: "Cloud Machine 2",
                                             state: CloudMachineState(status: .provisioning, pendingWorkspace: true)))
    }
}
#endif
