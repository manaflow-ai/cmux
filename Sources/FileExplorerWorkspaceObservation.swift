import Foundation
import Observation

/// One cancellable observation of the current workspace's Cloud authority.
/// Catalog churn can schedule only one re-observation; equal roots do no I/O.
@MainActor
final class FileExplorerWorkspaceObservation {
    weak var workspace: Workspace?
    private let resolver: FileExplorerWorkspaceRootResolver
    private let apply: (FileExplorerWorkspaceRoot) -> Void
    private var generation: UInt64 = 0
    private var previous: FileExplorerWorkspaceRoot?
    private var catalogObserver: NSObjectProtocol?

    init(workspace: Workspace, resolver: FileExplorerWorkspaceRootResolver,
         apply: @escaping (FileExplorerWorkspaceRoot) -> Void) {
        self.workspace = workspace
        self.resolver = resolver
        self.apply = apply
        catalogObserver = NotificationCenter.default.addObserver(
            forName: SurfaceCatalog.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak workspace] notification in
            MainActor.assumeIsolated {
                guard let self, let workspace,
                      let machine = workspace.cloudVMBinding?.vmID,
                      let changedMachines = notification.userInfo?["machines"] as? [String],
                      changedMachines.contains(machine) else { return }
                self.refresh(force: true)
            }
        }
    }

    func refresh(force: Bool = false) {
        guard let workspace else { return }
        generation &+= 1
        let generation = generation
        let root = withObservationTracking {
            resolver.resolve(workspace)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.refresh()
            }
        }
        guard force || previous != root else { return }
        previous = root
        apply(root)
    }

    func stop() {
        generation &+= 1
        if let catalogObserver {
            NotificationCenter.default.removeObserver(catalogObserver)
            self.catalogObserver = nil
        }
        workspace = nil
    }

    deinit {
        if let catalogObserver { NotificationCenter.default.removeObserver(catalogObserver) }
    }
}
