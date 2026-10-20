import Foundation

/// One cancellable observation of the current workspace's Cloud authority.
/// Catalog churn can schedule only one re-observation; equal roots do no I/O.
@MainActor
final class FileExplorerWorkspaceObservation {
    weak var workspace: Workspace?
    private let resolver: FileExplorerWorkspaceRootResolver
    private let apply: (FileExplorerWorkspaceRoot) -> Void
    private var previous: FileExplorerWorkspaceRoot?
    private var catalogObserver: NSObjectProtocol?
    private var directoryObserver: NSObjectProtocol?
    private var bindingChangesTask: Task<Void, Never>?

    init(workspace: Workspace, resolver: FileExplorerWorkspaceRootResolver,
         apply: @escaping (FileExplorerWorkspaceRoot) -> Void) {
        self.workspace = workspace
        self.resolver = resolver
        self.apply = apply
        directoryObserver = NotificationCenter.default.addObserver(
            forName: .workspaceCurrentDirectoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self, weak workspace] notification in
            MainActor.assumeIsolated {
                guard let self, let workspace,
                      (notification.object as? Workspace) === workspace ||
                        (notification.userInfo?["workspaceId"] as? UUID) == workspace.id else { return }
                self.refresh()
            }
        }
        catalogObserver = NotificationCenter.default.addObserver(
            forName: SurfaceCatalog.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak workspace] notification in
            MainActor.assumeIsolated {
                guard let self, let workspace,
                      let machine = workspace.cloudVMBinding?.vmID else { return }
                if let changedMachines = notification.userInfo?["machines"] as? [String],
                   !changedMachines.contains(machine) { return }
                self.refresh()
            }
        }
        bindingChangesTask = Task { @MainActor [weak self, weak workspace] in
            guard let workspace else { return }
            for await _ in workspace.cloudBindingState.changes() {
                guard let self, self.workspace === workspace else { return }
                self.refresh()
            }
        }
    }

    func refresh(force: Bool = false) {
        guard let workspace else { return }
        let root = resolver.resolve(workspace)
        guard force || previous != root else { return }
        previous = root
        apply(root)
    }

    func stop() {
        bindingChangesTask?.cancel()
        bindingChangesTask = nil
        if let directoryObserver {
            NotificationCenter.default.removeObserver(directoryObserver)
            self.directoryObserver = nil
        }
        if let catalogObserver {
            NotificationCenter.default.removeObserver(catalogObserver)
            self.catalogObserver = nil
        }
        workspace = nil
    }

    deinit {
        bindingChangesTask?.cancel()
        if let directoryObserver { NotificationCenter.default.removeObserver(directoryObserver) }
        if let catalogObserver { NotificationCenter.default.removeObserver(catalogObserver) }
    }
}
