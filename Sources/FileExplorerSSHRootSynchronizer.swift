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
        // Cancel any in-flight stop/update so a delayed monitor.stop() cannot
        // finish a freshly opened updates() stream.
        monitorUpdateTask?.cancel()
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
        observationTask?.cancel()
        observationTask = nil
        snapshot = nil
        // Serialize shutdown through the owned monitor-update task so stop
        // cannot race a newly enqueued update or observation restart.
        monitorUpdateTask?.cancel()
        let monitor = monitor
        monitorUpdateTask = Task {
            guard !Task.isCancelled else { return }
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
