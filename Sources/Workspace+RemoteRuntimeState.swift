import CmuxRemoteDaemon
import CmuxSidebar
import Foundation

extension SessionWorkspaceSnapshot {
    func portableRemoteRuntimeStateSnapshot() -> SessionWorkspaceSnapshot {
        var snapshot = self
        snapshot.remote = nil
        for index in snapshot.panels.indices {
            guard var terminal = snapshot.panels[index].terminal else { continue }
            terminal.scrollback = nil
            snapshot.panels[index].terminal = terminal
        }
        return snapshot
    }
}

extension Workspace {
    func restoreRemoteConfiguration(
        from snapshot: SessionWorkspaceSnapshot,
        preservingActiveConnection: Bool
    ) {
        guard !preservingActiveConnection else { return }
        let restoredRemoteConfiguration = snapshot.remote?.workspaceConfiguration(
            localSocketPath: TerminalController.shared.currentSocketPathForRemoteRestore()
        )
        if let restoredRemoteConfiguration {
            let shouldAutoConnect = shouldAutoConnectRestoredRemote(restoredRemoteConfiguration, snapshot: snapshot)
            configureRemoteConnection(restoredRemoteConfiguration, autoConnect: shouldAutoConnect)
        } else {
            disconnectRemoteConnection(clearConfiguration: true)
        }
    }

    func restoreStatusEntries(
        from snapshot: SessionWorkspaceSnapshot,
        preservingRemoteRuntimeState: Bool
    ) {
        guard preservingRemoteRuntimeState else {
            statusEntries.removeAll()
            return
        }
        // Local snapshots must not resurrect process status after its process
        // exited. Remote PTYs remain alive, so retain their portable status.
        var restoredStatusEntries: [String: SidebarStatusEntry] = [:]
        for entry in snapshot.statusEntries where !entry.key.hasPrefix("remote.") {
            restoredStatusEntries[entry.key] = SidebarStatusEntry(
                key: entry.key,
                value: entry.value,
                icon: entry.icon,
                color: entry.color,
                timestamp: Date(timeIntervalSince1970: entry.timestamp)
            )
        }
        statusEntries = restoredStatusEntries
    }

    func resetRemoteRuntimeStateRevision(preservingPersistentIdentity: Bool) {
        if !preservingPersistentIdentity {
            remoteRuntimeStateRevision = 0
        }
    }

    func enqueueRemoteRuntimeState(_ sourceSnapshot: SessionWorkspaceSnapshot) {
        guard !isApplyingRemoteRuntimeState,
              let configuration = remoteConfiguration,
              configuration.persistentDaemonSlot != nil,
              let controller = remoteSessionControllerForRuntimeState else { return }

        let runtimeSnapshot = sourceSnapshot.portableRemoteRuntimeStateSnapshot()
        let baseRevision = remoteRuntimeStateRevision
        let schemaVersion = SessionSnapshotSchema.currentVersion
        // The app target remains Swift 5/Xcode 16 compatible, where
        // `@concurrent` is unavailable; a detached task keeps multi-megabyte
        // encoding off the main autosave path.
        remoteRuntimeStateEncodingPipeline.enqueue {
            guard !Task.isCancelled,
                  let state = try? JSONEncoder().encode(runtimeSnapshot),
                  !Task.isCancelled else { return }
            controller.enqueueRuntimeState(
                schemaVersion: schemaVersion,
                state: state,
                baseRevision: baseRevision
            )
        }
    }

    func teardownPanelsForClosePreservingRemoteRuntimeState() {
        if !isApplyingRemoteRuntimeState,
           remoteConfiguration?.persistentDaemonSlot != nil,
           remoteSessionControllerForRuntimeState != nil {
            enqueueRemoteRuntimeState(sessionSnapshot(includeScrollback: false))
        }
        withClosedPanelHistorySuppressed {
            teardownAllPanels()
        }
    }

    func applyRemoteRuntimeState(
        _ document: RemoteRuntimeStateDocument,
        snapshot sourceSnapshot: SessionWorkspaceSnapshot
    ) {
        guard document.revision != remoteRuntimeStateRevision else { return }
        guard document.schemaVersion == SessionSnapshotSchema.currentVersion,
              let configuration = remoteConfiguration,
              configuration.persistentDaemonSlot != nil else { return }

        remoteRuntimeStateRevision = document.revision
        var snapshot = sourceSnapshot
        snapshot.remote = configuration.sessionSnapshot()
        isApplyingRemoteRuntimeState = true
        defer { isApplyingRemoteRuntimeState = false }
        _ = restoreSessionSnapshot(snapshot, restoringRemoteRuntime: true)
    }

    func acknowledgeRemoteRuntimeStateRevision(_ revision: UInt64) {
        remoteRuntimeStateRevision = revision
    }
}
