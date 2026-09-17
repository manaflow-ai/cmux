import CMUXAgentLaunch
import Foundation

extension Workspace {
    /// Whether `restoredAgent` is verifiably still running in `panelId`; see
    /// `RestoredAgentLiveness` for the evidence order shared with the Dock.
    func restoredAgentHasLiveProcess(
        _ restoredAgent: SessionRestorableAgentSnapshot,
        panelId: UUID
    ) -> Bool {
        let key = RestoredAgentLiveness.pidKey(for: restoredAgent)
        let recordedProcess: RestoredAgentLiveness.RecordedProcess? = {
            guard agentPIDKeysByPanelId[panelId]?.contains(key) == true,
                  let pid = agentPIDs[key] else {
                return nil
            }
            return RestoredAgentLiveness.RecordedProcess(
                pid: pid,
                identity: agentPIDProcessIdentitiesByKey[key]
            )
        }()
        return RestoredAgentLiveness().hasLiveProcess(
            restoredAgent,
            workspaceId: id,
            panelId: panelId,
            recordedProcess: recordedProcess,
            liveIndex: SharedLiveAgentIndex.shared.index,
            foregroundProcessID: terminalPanel(for: panelId)?.surface.foregroundProcessID()
        )
    }

    /// The same evidence for a hook-published binding that carries no
    /// restored snapshot of its own.
    func agentHookBindingHasLiveProcess(panelId: UUID) -> Bool {
        guard let binding = surfaceResumeBindingsByPanelId[panelId],
              binding.isAgentHookBinding,
              let agent = binding.managedRestorableAgentSnapshot(
                  replacing: restoredAgentSnapshotsByPanelId[panelId]
              ) else {
            return false
        }
        return restoredAgentHasLiveProcess(agent, panelId: panelId)
    }

    /// Whether a restore deferred behind its ownership scan still targets
    /// `binding`'s session. Until the scan admits or cancels that launch, the
    /// binding has no running process by design.
    func deferredAgentResumeRestoreOwns(
        _ binding: SurfaceResumeBindingSnapshot,
        panelId: UUID
    ) -> Bool {
        guard binding.isAgentHookBinding,
              let restore = deferredAgentResumeRestoresByPanelId[panelId] else {
            return false
        }
        if let capturedBinding = restore.resumeBinding {
            return capturedBinding.isSameManagedSession(as: binding)
        }
        guard let restorableAgent = restore.restorableAgent,
              let kind = binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines),
              let checkpointId = binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return restorableAgent.kind.rawValue == kind
            && ManagedAgentSessionIdentity.sessionIDsMatch(
                kind: kind,
                lhs: restorableAgent.sessionId,
                rhs: checkpointId
            )
    }

    /// True when `binding` is a plain (non-tmux) agent-hook resume binding
    /// whose session no longer shows up as a live process. Generalizes the
    /// tmux-only `isProcessDetected` staleness signal in
    /// `reconcileSurfaceResumeBindings` so a normal exit of a resumed
    /// non-tmux agent doesn't leave a binding that gets replayed automatically
    /// on the next relaunch (#8446).
    ///
    /// `restorableAgentIndex`, when supplied, is a freshly loaded index from
    /// the same scan generation as the caller's `SurfaceResumeBindingIndex`
    /// (see `ProcessDetectedResumeIndexes.load()`); prefer it over the
    /// separately TTL-cached `SharedLiveAgentIndex.shared.index` so pruning
    /// and the binding scan it is paired with always describe the same
    /// point-in-time snapshot instead of two independently stale ones.
    func isStaleAgentHookBinding(
        _ binding: SurfaceResumeBindingSnapshot,
        panelId: UUID,
        restorableAgentIndex: RestorableAgentSessionIndex? = nil
    ) -> Bool {
        // `RestorableAgentSessionIndex` / `SharedLiveAgentIndex` are built by
        // scanning LOCAL processes (pid/sysctl-based). A `.persistentSSH`
        // agent-hook binding's process runs on the remote host and can never
        // appear in that local scan, so treating it as this function's kind
        // of "stale" would prune every live remote agent-hook binding on the
        // very next reconciliation. Only judge local-launch bindings here;
        // remote bindings are left to whatever governs their own lifecycle.
        guard binding.isAgentHookBinding,
              binding.launchFlavor == .local,
              let checkpointId = binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !checkpointId.isEmpty,
              let kind = binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines),
              !kind.isEmpty else {
            return false
        }
        if restoredAgentLifecycleOwns(binding, panelId: panelId) {
            return false
        }
        // A restore still deferred behind its ownership scan has not launched
        // yet, so the absence of a live process is expected rather than proof
        // that the agent exited. Retiring here would make the scan cancel the
        // launch and restore a bare shell (#12084).
        if deferredAgentResumeRestoreOwns(binding, panelId: panelId) {
            return false
        }
        let liveIndex = restorableAgentIndex ?? SharedLiveAgentIndex.shared.index
        // Missing index data is unknown evidence, not proof that the agent
        // exited. Preserve automatic ownership until a completed scan can
        // establish liveness (or an explicit lifecycle event retires it).
        guard let liveIndex else { return false }
        guard !liveIndex.hasAmbiguousPanel(panelId) else { return false }
        // A recorded PID with unknown cached liveness is inconclusive, not an
        // exited session. Preserve the automatic binding until a later scan
        // can establish that the process is gone.
        guard liveIndex.hasUncertainStablePanelEntry(
            panelId: panelId,
            revalidateProcessEvidence: false
        ) != true else {
            return false
        }
        let liveEntry = liveIndex.entryForStablePanel(
            workspaceId: id,
            panelId: panelId,
            revalidateProcessEvidence: false
        )
        return !AgentResumeLiveness.hasLiveProcess(
            for: liveEntry,
            kind: kind,
            sessionId: checkpointId
        )
    }

}
