import Foundation

extension Workspace {
    /// Resolves the parent snapshot used by a fork startup record.
    ///
    /// Lifecycle-owned snapshots are the authoritative in-process binding. If
    /// a caller only has an availability-cache snapshot, refresh the shared
    /// index off the main actor and require an exact workspace/panel identity
    /// before allowing it to be persisted on the new surface.
    @MainActor
    func authoritativeForkSnapshot(
        selected: SessionRestorableAgentSnapshot,
        panelId: UUID,
        isRemoteContext: Bool
    ) async -> SessionRestorableAgentSnapshot? {
        // Remote SSH/tmux forks keep their provider command on the remote
        // host and do not persist a local continuation record.
        if isRemoteContext {
            return selected
        }
        if let lifecycleSnapshot = restoredAgentSnapshotForContinuation(panelId: panelId),
           Self.forkSnapshotsMatch(lifecycleSnapshot, selected) {
            return lifecycleSnapshot
        }
        guard let index = await SharedLiveAgentIndex.shared.indexRefreshingNow(),
              index.isComplete(
                  forWorkspaceId: id,
                  panelId: panelId,
                  kind: selected.kind.rawValue
              ),
              let entry = index.exactEntry(workspaceId: id, panelId: panelId),
              Self.forkSnapshotsMatch(entry.snapshot, selected) else {
            return nil
        }
        return entry.snapshot
    }

    /// Selects the fork startup input for one source panel. A matching local
    /// binding uses the canonicalizer so binding-driven and snapshot-driven
    /// launches share the same `cmux fork` selector; other locations use the
    /// snapshot's provider command fallback.
    func forkStartupInput(
        snapshot: SessionRestorableAgentSnapshot,
        panelId: UUID,
        useLocalForkVerb: Bool,
        fileManager: FileManager,
        temporaryDirectory: URL,
        allowLauncherScript: Bool,
        dialect: TerminalStartupShellDialect
    ) -> String? {
        if useLocalForkVerb,
           let binding = surfaceResumeBinding(panelId: panelId),
           binding.matchesForkSnapshot(snapshot),
           let input = binding.forkStartupInput() {
            return input
        }
        return snapshot.forkStartupInput(
            useLocalForkVerb: useLocalForkVerb,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory,
            allowLauncherScript: allowLauncherScript,
            dialect: dialect
        )
    }
}

private extension Workspace {
    static func forkSnapshotsMatch(
        _ lhs: SessionRestorableAgentSnapshot,
        _ rhs: SessionRestorableAgentSnapshot
    ) -> Bool {
        lhs.kind == rhs.kind
            && ManagedAgentSessionIdentity.sessionIDsMatch(
                kind: lhs.kind.rawValue,
                lhs: lhs.sessionId,
                rhs: rhs.sessionId
            )
    }
}

private extension SurfaceResumeBindingSnapshot {
    /// Matches a binding to the immutable snapshot selected by the fork action.
    func matchesForkSnapshot(_ snapshot: SessionRestorableAgentSnapshot) -> Bool {
        guard let bindingKind = kind?.trimmingCharacters(in: .whitespacesAndNewlines),
              let bindingCheckpoint = checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bindingKind.isEmpty,
              !bindingCheckpoint.isEmpty else {
            return false
        }
        return bindingKind.caseInsensitiveCompare(snapshot.kind.rawValue) == .orderedSame
            && bindingCheckpoint == snapshot.sessionId
    }
}
