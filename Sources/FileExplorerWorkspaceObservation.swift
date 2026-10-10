import Foundation

/// One cancellable observation of the current workspace's Files authority.
///
/// Workspace roots are resolved from the selected panel only. Plain SSH
/// detection runs off the main actor when that selection, its TTY, or its
/// stable title changes; cwd reports re-resolve the current root without
/// polling terminal output.
@MainActor
final class FileExplorerWorkspaceObservation {
    weak var workspace: Workspace?
    private let resolver: FileExplorerWorkspaceRootResolver
    private let apply: (FileExplorerWorkspaceRoot) -> Void
    private let sshSessionMonitor: FileExplorerSSHSessionMonitor
    private var previous: FileExplorerWorkspaceRoot?
    private var catalogObserver: NSObjectProtocol?
    private var directoryObserver: NSObjectProtocol?
    private var focusObserver: NSObjectProtocol?
    private var titleObserver: NSObjectProtocol?
    private var shellActivityObserver: NSObjectProtocol?
    private var remotePresentationObserver: NSObjectProtocol?
    private var bindingChangesTask: Task<Void, Never>?
    private var sshObservationTask: Task<Void, Never>?
    private var sshMonitorUpdateTask: Task<Void, Never>?
    private var detectionContext: DetectionContext?
    private var detectedSSHSession: DetectedSSHSession?
    private var lastSelectedStableTitle: String?

    private struct DetectionContext: Equatable {
        let workspaceId: UUID
        let panelId: UUID
        let ttyName: String
    }

    init(
        workspace: Workspace,
        resolver: FileExplorerWorkspaceRootResolver,
        sshSessionMonitor: FileExplorerSSHSessionMonitor = FileExplorerSSHSessionMonitor(),
        apply: @escaping (FileExplorerWorkspaceRoot) -> Void
    ) {
        self.workspace = workspace
        self.resolver = resolver
        self.sshSessionMonitor = sshSessionMonitor
        self.apply = apply

        sshObservationTask = Task { @MainActor [weak self, weak workspace] in
            let updates = await sshSessionMonitor.updates()
            for await snapshot in updates {
                guard let self, let workspace, self.workspace === workspace else { return }
                self.applySSHSnapshot(snapshot, for: workspace)
            }
        }

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
        focusObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { [weak self, weak workspace] notification in
            MainActor.assumeIsolated {
                guard let self, let workspace,
                      (notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID) == workspace.id else { return }
                self.refresh(force: true)
            }
        }
        titleObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidSetTitle,
            object: nil,
            queue: .main
        ) { [weak self, weak workspace] notification in
            MainActor.assumeIsolated {
                guard let self, let workspace,
                      let change = GhosttyTitleChange(notification: notification),
                      change.tabId == workspace.id,
                      change.surfaceId == workspace.focusedPanelId,
                      let terminal = workspace.terminalPanel(for: change.surfaceId),
                      change.matches(
                          sourceSurface: terminal.surface,
                          terminalLifecycleID: terminal.surface.terminalLifecycleId
                      ),
                      self.lastSelectedStableTitle != change.stableTitle else { return }
                self.lastSelectedStableTitle = change.stableTitle
                self.refresh(force: true)
            }
        }
        shellActivityObserver = NotificationCenter.default.addObserver(
            forName: .workspaceShellActivityDidChange,
            object: workspace,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh(force: true)
            }
        }
        remotePresentationObserver = NotificationCenter.default.addObserver(
            forName: .workspaceRemoteConnectionPresentationDidChange,
            object: workspace,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
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
        updateSSHDetection(for: workspace, force: force)
        let remoteCwd = detectedSSHSession == nil
            ? nil
            : workspace.fileExplorerSelectedTerminalContext?.remoteWorkingDirectory
        let root = resolver.resolve(
            workspace,
            detectedSSHSession: detectedSSHSession,
            detectedRemoteWorkingDirectory: remoteCwd
        )
        guard force || previous != root else { return }
        previous = root
        apply(root)
    }

    func stop() {
        bindingChangesTask?.cancel()
        bindingChangesTask = nil
        sshObservationTask?.cancel()
        sshObservationTask = nil
        sshMonitorUpdateTask?.cancel()
        sshMonitorUpdateTask = Task { [sshSessionMonitor] in
            await sshSessionMonitor.stop()
        }
        if let directoryObserver {
            NotificationCenter.default.removeObserver(directoryObserver)
            self.directoryObserver = nil
        }
        if let focusObserver {
            NotificationCenter.default.removeObserver(focusObserver)
            self.focusObserver = nil
        }
        if let titleObserver {
            NotificationCenter.default.removeObserver(titleObserver)
            self.titleObserver = nil
        }
        if let shellActivityObserver {
            NotificationCenter.default.removeObserver(shellActivityObserver)
            self.shellActivityObserver = nil
        }
        if let remotePresentationObserver {
            NotificationCenter.default.removeObserver(remotePresentationObserver)
            self.remotePresentationObserver = nil
        }
        if let catalogObserver {
            NotificationCenter.default.removeObserver(catalogObserver)
            self.catalogObserver = nil
        }
        detectionContext = nil
        detectedSSHSession = nil
        workspace = nil
    }

    private func updateSSHDetection(for workspace: Workspace, force: Bool) {
        guard let selectedContext = workspace.fileExplorerSelectedTerminalContext else {
            guard detectionContext != nil || detectedSSHSession != nil else { return }
            detectionContext = nil
            detectedSSHSession = nil
            sshMonitorUpdateTask?.cancel()
            sshMonitorUpdateTask = Task { [sshSessionMonitor] in
                await sshSessionMonitor.update(
                    isEnabled: false,
                    workspaceId: nil,
                    panelId: nil,
                    ttyName: nil
                )
            }
            return
        }

        let nextContext = DetectionContext(
            workspaceId: selectedContext.workspaceId,
            panelId: selectedContext.panelId,
            ttyName: selectedContext.ttyName
        )
        let contextChanged = detectionContext != nextContext
        guard force || contextChanged else { return }
        detectionContext = nextContext
        if contextChanged {
            detectedSSHSession = nil
        }
        sshMonitorUpdateTask?.cancel()
        sshMonitorUpdateTask = Task { [sshSessionMonitor] in
            await sshSessionMonitor.update(
                isEnabled: true,
                workspaceId: nextContext.workspaceId,
                panelId: nextContext.panelId,
                ttyName: nextContext.ttyName,
                force: force
            )
        }
    }

    private func applySSHSnapshot(
        _ snapshot: FileExplorerSSHSessionMonitor.Snapshot?,
        for workspace: Workspace
    ) {
        guard let snapshot else {
            guard detectionContext == nil else { return }
            detectedSSHSession = nil
            refresh()
            return
        }
        guard snapshot.workspaceId == workspace.id,
              snapshot.panelId == workspace.focusedPanelId,
              detectionContext == DetectionContext(
                  workspaceId: snapshot.workspaceId,
                  panelId: snapshot.panelId,
                  ttyName: snapshot.ttyName
              ) else { return }
        detectedSSHSession = snapshot.session
        refresh()
    }

    deinit {
        bindingChangesTask?.cancel()
        sshObservationTask?.cancel()
        sshMonitorUpdateTask?.cancel()
        if let directoryObserver { NotificationCenter.default.removeObserver(directoryObserver) }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        if let titleObserver { NotificationCenter.default.removeObserver(titleObserver) }
        if let shellActivityObserver { NotificationCenter.default.removeObserver(shellActivityObserver) }
        if let remotePresentationObserver { NotificationCenter.default.removeObserver(remotePresentationObserver) }
        if let catalogObserver { NotificationCenter.default.removeObserver(catalogObserver) }
    }
}
