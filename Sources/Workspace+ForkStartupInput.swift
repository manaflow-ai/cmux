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
            return await revalidatedForkSnapshotIfNeeded(
                lifecycleSnapshot,
                selected: selected,
                panelId: panelId
            )
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
        return await revalidatedForkSnapshotIfNeeded(
            entry.snapshot,
            selected: selected,
            panelId: panelId
        )
    }

    private func revalidatedForkSnapshotIfNeeded(
        _ candidate: SessionRestorableAgentSnapshot,
        selected: SessionRestorableAgentSnapshot,
        panelId: UUID
    ) async -> SessionRestorableAgentSnapshot? {
        let selectedIdentity = AgentForkSupport.forkValidationIdentity(
            snapshot: selected,
            isRemoteContext: false
        )
        let candidateIdentity = AgentForkSupport.forkValidationIdentity(
            snapshot: candidate,
            isRemoteContext: false
        )
        guard let candidateIdentity else { return nil }
        guard candidateIdentity != selectedIdentity else { return candidate }

        // A fresh lifecycle/index read can replace executable or registration
        // metadata while retaining the same session id. Re-run the capability
        // probe for that exact candidate and refresh cache metadata before
        // persisting it on the destination surface.
        await SharedLiveAgentIndex.shared.refreshForkAvailabilityNow(
            workspaceId: id,
            panelId: panelId,
            isRemoteContext: false,
            fallbackSnapshot: candidate
        )
        guard SharedLiveAgentIndex.shared.forkSupportProbeAccepted(
            workspaceId: id,
            panelId: panelId,
            isRemoteContext: false,
            fallbackSnapshot: candidate
        ) else {
            return nil
        }
        return candidate
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
        return bindingKind == snapshot.kind.rawValue
            && bindingCheckpoint == snapshot.sessionId
    }
}
