import Combine
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
    private var workspaceCancellables: Set<AnyCancellable> = []
    private var bindingChangesTask: Task<Void, Never>?
    private var sshObservationTask: Task<Void, Never>?
    private var sshMonitorUpdateTask: Task<Void, Never>?
    private var detectionContext: DetectionContext?
    private var detectedSSHSession: DetectedSSHSession?
    private var lastPanelTitles: [UUID: String] = [:]

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
        self.lastPanelTitles = workspace.panelTitles

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

        workspace.$panelTitles
            .sink { [weak self, weak workspace] titles in
                guard let self, let workspace, self.workspace === workspace else { return }
                let panelId = workspace.focusedPanelId
                let selectedTitleChanged = panelId.map {
                    self.lastPanelTitles[$0] != titles[$0]
                } ?? false
                self.lastPanelTitles = titles
                self.refresh(force: selectedTitleChanged)
            }
            .store(in: &workspaceCancellables)
        workspace.$panelDirectories
            .sink { [weak self, weak workspace] _ in
                guard let self, let workspace, self.workspace === workspace else { return }
                self.refresh()
            }
            .store(in: &workspaceCancellables)
        workspace.$remoteConfiguration
            .sink { [weak self, weak workspace] _ in
                guard let self, let workspace, self.workspace === workspace else { return }
                self.refresh()
            }
            .store(in: &workspaceCancellables)
        workspace.$remoteConnectionState
            .sink { [weak self, weak workspace] _ in
                guard let self, let workspace, self.workspace === workspace else { return }
                self.refresh()
            }
            .store(in: &workspaceCancellables)
        workspace.$remoteConnectionDetail
            .sink { [weak self, weak workspace] _ in
                guard let self, let workspace, self.workspace === workspace else { return }
                self.refresh()
            }
            .store(in: &workspaceCancellables)
        workspace.$remoteDaemonStatus
            .sink { [weak self, weak workspace] _ in
                guard let self, let workspace, self.workspace === workspace else { return }
                self.refresh()
            }
            .store(in: &workspaceCancellables)

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
        let remoteCwd = detectedSSHSession.flatMap { _ in
            workspace.focusedPanelId
                .flatMap { workspace.panelTitles[$0] }
                .flatMap(TerminalSSHSessionDetector.remoteWorkingDirectory(fromTitle:))
        }
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
        if let catalogObserver {
            NotificationCenter.default.removeObserver(catalogObserver)
            self.catalogObserver = nil
        }
        workspaceCancellables.removeAll()
        detectionContext = nil
        detectedSSHSession = nil
        workspace = nil
    }

    private func updateSSHDetection(for workspace: Workspace, force: Bool) {
        guard !workspace.usesRemoteDirectoryProvenance,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId),
              workspace.hasCurrentRuntimeReportedTTY(panelId: panelId, terminal: terminalPanel),
              let ttyName = workspace.surfaceTTYNames[panelId]
                .map({ TerminalSSHSessionDetector.normalizeTTYName($0) }),
              !ttyName.isEmpty else {
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

        let nextContext = DetectionContext(workspaceId: workspace.id, panelId: panelId, ttyName: ttyName)
        guard force || detectionContext != nextContext else { return }
        detectionContext = nextContext
        detectedSSHSession = nil
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
            detectedSSHSession = nil
            refresh(force: true)
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
        refresh(force: true)
    }

    deinit {
        bindingChangesTask?.cancel()
        sshObservationTask?.cancel()
        sshMonitorUpdateTask?.cancel()
        if let directoryObserver { NotificationCenter.default.removeObserver(directoryObserver) }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        if let catalogObserver { NotificationCenter.default.removeObserver(catalogObserver) }
    }
}
