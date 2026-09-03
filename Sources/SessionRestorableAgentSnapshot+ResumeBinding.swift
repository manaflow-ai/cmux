import Foundation
import CMUXAgentLaunch

extension SessionRestorableAgentSnapshot {
    /// Whether this snapshot carries enough app-owned identity to authorize an
    /// automatic resume.
    ///
    /// Session-file and fork-parent process scans can identify a plausible
    /// conversation for display, but they cannot establish ownership of the
    /// surface. Only hook-backed identity (or an explicitly reported process
    /// identity) may drive an automatic resume. Codex additionally requires
    /// verified top-level TUI provenance.
    var hasAuthoritativeResumeIdentity: Bool {
        guard kind.restoreMode == .resumeSession else { return true }
        if let processDetectedSessionIDSource,
           processDetectedSessionIDSource != .explicit {
            return false
        }
        if kind.rawValue.lowercased() == "codex" {
            return resumeEvidenceProvenance?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == AgentResumeEvidenceProvenance.tui.logValue
        }
        return true
    }

    /// Uses an authoritative agent-hook checkpoint when process discovery
    /// represented the same Pi/OMP session by its JSONL path.
    func retargetedForResumeBinding(
        _ binding: SurfaceResumeBindingSnapshot?
    ) -> Self {
        guard let binding,
              binding.isAgentHookBinding,
              let checkpointId = binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !checkpointId.isEmpty,
              ManagedAgentSessionIdentity.sessionIDsMatch(
                  kind: kind.rawValue,
                  lhs: sessionId,
                  rhs: checkpointId
              ) else {
            return self
        }
        var retargeted = self
        if sessionId != checkpointId {
            retargeted.sessionId = checkpointId
        }
        if kind.rawValue.lowercased() == "codex",
           let provenance = binding.resumeEvidenceProvenance {
            retargeted.resumeEvidenceProvenance = provenance
        }
        return retargeted
    }

    /// Keeps verified Codex ownership when a process observation refreshes
    /// liveness for the same session but carries no binding provenance itself.
    func preservingCodexResumeEvidence(
        from previous: SessionRestorableAgentSnapshot?
    ) -> Self {
        guard kind.rawValue.lowercased() == "codex",
              resumeEvidenceProvenance == nil,
              let previous,
              previous.kind.rawValue.lowercased() == "codex",
              ManagedAgentSessionIdentity.sessionIDsMatch(
                  kind: kind.rawValue,
                  lhs: sessionId,
                  rhs: previous.sessionId
              ),
              let provenance = previous.resumeEvidenceProvenance else {
            return self
        }
        var preserved = self
        preserved.resumeEvidenceProvenance = provenance
        return preserved
    }

    /// Builds the durable hook binding that can resume this agent session.
    ///
    /// The snapshot is the app's authoritative, structured identity for an agent. Keeping the
    /// binding derivation here gives session-save backfill and restore-time repair one command and
    /// working-directory policy instead of allowing each persistence owner to reconstruct it.
    func resumeBindingSnapshot(
        launchFlavor: SurfaceResumeLaunchFlavor = .local
    ) -> SurfaceResumeBindingSnapshot? {
        guard kind.restoreMode == .resumeSession else { return nil }
        guard launchCommand?.source?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() != "rejected" else { return nil }
        guard hasAuthoritativeResumeIdentity else { return nil }
        var bindingAgent = self
        if bindingAgent.registration?.cwd == .ignore {
            bindingAgent.workingDirectory = nil
            bindingAgent.launchCommand?.workingDirectory = nil
        }
        let resolvedWorkingDirectory = AgentResumeWorkingDirectory().resolve(
            kind: bindingAgent.kind.rawValue,
            runtimeCwd: bindingAgent.workingDirectory,
            launchWorkingDirectory: bindingAgent.launchCommand?.workingDirectory
        )
        guard let command = bindingAgent.resumeCommand(
            includeWorkingDirectoryPrefix: true,
            restoringWorkingDirectory: resolvedWorkingDirectory
        ) else {
            return nil
        }
        return SurfaceResumeBindingSnapshot(
            name: bindingAgent.agentDisplayName,
            kind: bindingAgent.kind.rawValue,
            command: command,
            cwd: resolvedWorkingDirectory,
            checkpointId: bindingAgent.sessionId,
            source: "agent-hook",
            environment: bindingAgent.launchCommand?.environment,
            launchCommand: bindingAgent.launchCommand,
            permissionMode: bindingAgent.permissionMode,
            autoResume: true,
            resumeEvidenceProvenance: bindingAgent.resumeEvidenceProvenance,
            launchFlavor: launchFlavor
        )
    }
}
