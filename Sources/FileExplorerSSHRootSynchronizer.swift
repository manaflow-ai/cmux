import Foundation

/// Shared SSH-aware file-tree root sync path used by ContentView and RightSidebarToolPanel.
@MainActor
final class FileExplorerSSHRootSynchronizer {
    private let monitor: FileExplorerSSHSessionMonitor
    private let resolver = FileExplorerWorkspaceRootResolver()
    private var monitorUpdateTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?
    private(set) var snapshot: FileExplorerSSHSessionMonitor.Snapshot?

    init(monitor: FileExplorerSSHSessionMonitor = FileExplorerSSHSessionMonitor()) {
        self.monitor = monitor
    }

    func startObserving(onChange: @escaping @MainActor () -> Void) {
        observationTask?.cancel()
        let monitor = monitor
        observationTask = Task { [weak self] in
            let updates = await monitor.updates()
            for await snapshot in updates {
                guard !Task.isCancelled, let self else { return }
                self.snapshot = snapshot
                onChange()
            }
        }
    }

    func stop() {
        monitorUpdateTask?.cancel()
        observationTask?.cancel()
        monitorUpdateTask = nil
        observationTask = nil
        snapshot = nil
        let monitor = monitor
        Task {
            await monitor.stop()
        }
    }

    func clear(store: FileExplorerStore) {
        store.applyWorkspaceRoot(.none)
        enqueueMonitorUpdate(isEnabled: false, workspaceId: nil, ttyName: nil)
    }

    func applyWorkspaceRoot(
        workspace: Workspace,
        store: FileExplorerStore,
        isEnabled: Bool
    ) {
        store.showHiddenFiles = true
        let ttyName = workspace.focusedPanelId.flatMap { workspace.surfaceTTYNames[$0] }
        let shouldMonitor = isEnabled && !workspace.usesRemoteDirectoryProvenance
        enqueueMonitorUpdate(
            isEnabled: shouldMonitor,
            workspaceId: workspace.id,
            ttyName: ttyName
        )

        let detectedSSHSession: DetectedSSHSession?
        if let snapshot,
           snapshot.workspaceId == workspace.id,
           snapshot.ttyName == ttyName {
            detectedSSHSession = snapshot.session
        } else {
            detectedSSHSession = nil
        }
        store.applyWorkspaceRoot(
            resolver.resolve(
                workspace: workspace,
                detectedSSHSession: detectedSSHSession
            )
        )
    }

    private func enqueueMonitorUpdate(
        isEnabled: Bool,
        workspaceId: UUID?,
        ttyName: String?
    ) {
        monitorUpdateTask?.cancel()
        let monitor = monitor
        monitorUpdateTask = Task {
            await monitor.update(
                isEnabled: isEnabled,
                workspaceId: workspaceId,
                ttyName: ttyName
            )
        }
    }
}
