import Foundation
import CMUXAgentLaunch
import OSLog

nonisolated private let codexResumeBindingLogger = Logger(
    subsystem: "com.cmuxterm.cli",
    category: "CodexResumeBinding"
)

extension CMUXCLI {
    /// Verifies a hook checkpoint before the standalone CLI publishes it.
    ///
    /// Hook publication is intentionally decided in this short-lived CLI
    /// process, not on cmux's MainActor or socket worker. The verifier starts
    /// with one indexed SQLite lookup and applies hard byte, line, and fallback
    /// candidate limits to the legacy rollout path, so the bounded inspection
    /// cannot turn an app UI/socket lane into a history loader.
    func codexResumeBindingVerification(
        sessionId: String,
        transcriptPath: String?,
        launchCommand: AgentHookLaunchCommandRecord?
    ) -> CodexSessionResumeVerification {
        let environment = ProcessInfo.processInfo.environment
        let codexHome = codexResumeBindingEffectiveHome(
            launchEnvironment: launchCommand?.environment,
            launchWorkingDirectory: launchCommand?.workingDirectory,
            launchVerificationHome: launchCommand?.verificationHome,
            ambientEnvironment: environment
        )
        return CodexSessionResumeVerifier().verify(
            sessionId: sessionId,
            transcriptPath: transcriptPath,
            codexHome: codexHome
        )
    }

    func codexResumeBindingEffectiveHome(
        launchEnvironment: [String: String]?,
        launchWorkingDirectory: String? = nil,
        launchVerificationHome: String? = nil,
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        CodexHomeResolver().resolve(
            launchEnvironment: launchEnvironment,
            launchWorkingDirectory: launchWorkingDirectory,
            launchVerificationHome: launchVerificationHome,
            ambientEnvironment: ambientEnvironment,
            fallbackHomeDirectory: NSHomeDirectory()
        )
    }

    /// Revalidates a structured Codex resume record at the last safe boundary
    /// before execve. Publication verification protects new hook events, but
    /// snapshots written by older builds can outlive that gate. A binding
    /// provenance check is applied only when the current surface still claims
    /// the checkpoint through an agent hook; explicit persisted exec records
    /// remain usable when they are not surface owners.
    func codexRestoreValidation(
        record: RestoreRecord,
        bindingPayload: [String: Any]?,
        processEnvironment: [String: String]
    ) -> CodexRestoreValidationResult? {
        guard record.mode == AgentRestoreRequestMode.resumeAgent.rawValue,
              record.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "codex",
              let sessionId = normalizedHookValue(record.checkpointID) else {
            return nil
        }
        if let bindingCheckpoint = codexRestoreBindingCheckpoint(bindingPayload),
           bindingCheckpoint != sessionId {
            // The app returned a newer parent (or another session) after the
            // restore selector was persisted. Never execute the stale record,
            // and never clear the newer binding.
            return .bindingChanged
        }

        var launchEnvironment = record.launchCommand?.environment ?? [:]
        launchEnvironment.merge(record.environment) { _, restored in restored }
        let codexHome = codexResumeBindingEffectiveHome(
            launchEnvironment: launchEnvironment,
            launchWorkingDirectory: record.launchCommand?.workingDirectory
                ?? record.workingDirectory,
            launchVerificationHome: record.launchCommand?.verificationHome,
            ambientEnvironment: processEnvironment
        )
        let verification = CodexSessionResumeVerifier().verify(
            sessionId: sessionId,
            transcriptPath: nil,
            codexHome: codexHome,
            allowLegacyFallbackForIndexedMissing: true
        )
        switch verification {
        case .exists(let evidence):
            return isCodexRestoreBindingOwner(
                bindingPayload,
                checkpointID: sessionId
            ) && !evidence.provenance.mayOwnBinding
                ? .rejectedChild(evidence)
                : .allowed(evidence)
        case .missing:
            // The restore-mode verifier has already attempted the bounded
            // rollout bridge for a readable index. A remaining miss is
            // definitive and may retire the guarded stale binding.
            return .missing
        case .unavailable:
            return .unavailable
        }
    }

    /// Leaves the shell in the recorded directory, then retires only the
    /// stale checkpoint that was actually rejected. The checkpoint guard in
    /// surface.resume.clear means a concurrently published parent binding is
    /// never cleared by this recovery path.
    func handleRejectedCodexRestore(
        _ result: CodexRestoreValidationResult,
        record: RestoreRecord,
        bindingPayload: [String: Any]?,
        surfaceID: String?,
        workspaceID: String?,
        client: SocketClient
    ) throws {
        let shouldHandle: Bool
        switch result {
        case .allowed:
            shouldHandle = false
        case .missing, .unavailable, .rejectedChild, .bindingChanged:
            shouldHandle = true
        }
        guard shouldHandle else { return }

        // applyRestoreWorkingDirectory deliberately runs before the guarded
        // clear. If the saved path is inaccessible, keep the binding intact so
        // the user can repair the path and retry rather than losing the parent.
        // A binding-change response is different: the returned record is stale,
        // so do not move the shell away from the newer parent's cwd.
        if case .bindingChanged = result {
            // Preserve the current shell directory and the authoritative binding.
        } else {
            let workingDirectory = requestedRestoreWorkingDirectory(for: record)
                ?? normalizedHookValue(bindingPayload?["cwd"] as? String)
            _ = try applyRestoreWorkingDirectory(workingDirectory)
        }

        let shouldClear: Bool
        switch result {
        case .missing, .rejectedChild:
            shouldClear = true
        case .allowed, .unavailable, .bindingChanged:
            shouldClear = false
        }
        if shouldClear,
           isCodexRestoreBindingOwner(bindingPayload, checkpointID: record.checkpointID),
           let surfaceID,
           let checkpointID = normalizedHookValue(record.checkpointID) {
            let outcome = clearAgentSurfaceResumeBindingOutcome(
                client: client,
                workspaceId: workspaceID ?? "",
                surfaceId: surfaceID,
                sessionId: checkpointID,
                sessionDidEnd: true
            )
            if outcome == .failed {
                codexResumeBindingLogger.notice(
                    "Codex stale restore clear failed; retaining checkpoint guard"
                )
            }
        }

        let message: String
        let stage: String
        switch result {
        case .bindingChanged:
            stage = "codex.restore.binding-changed"
            message = String(
                localized: "cli.restore.error.checkpointMismatch",
                defaultValue: "restore: this command no longer matches the session. Run 'cmux restore --surface' to use the current record."
            )
        case .allowed:
            return
        case .missing, .unavailable, .rejectedChild:
            stage = "codex.restore.checkpoint-unavailable"
            message = String(
                localized: "cli.restore.codexCheckpointUnavailable",
                defaultValue: "restore: the saved agent session is unavailable. The terminal remains in its saved directory; retry later or start a new agent session."
            )
        }
        // A rejected restore is a command failure, not a successful fallback.
        // Throw through the normal CLI boundary so callers receive a non-zero
        // status without exposing raw provider output.
        throw loggedRestoreError(stage: stage, message: message)
    }

    private func codexRestoreBindingCheckpoint(
        _ bindingPayload: [String: Any]?
    ) -> String? {
        guard let bindingPayload,
              let source = normalizedHookValue(bindingPayload["source"] as? String),
              source.lowercased() == "agent-hook",
              (normalizedHookValue(bindingPayload["kind"] as? String)?.lowercased() ?? "codex") == "codex" else {
            return nil
        }
        return normalizedHookValue(
            (bindingPayload["checkpoint_id"] as? String)
                ?? (bindingPayload["checkpointId"] as? String)
        )
    }

    private func isCodexRestoreBindingOwner(
        _ bindingPayload: [String: Any]?,
        checkpointID: String?
    ) -> Bool {
        guard let bindingCheckpoint = codexRestoreBindingCheckpoint(bindingPayload),
              let checkpointID = normalizedHookValue(checkpointID) else {
            return false
        }
        return bindingCheckpoint == checkpointID
    }

    func logCodexResumeBindingRejection(
        reason: String,
        sessionId: String,
        incoming: AgentResumeEvidenceProvenance?,
        existing: AgentResumeEvidenceProvenance?,
        telemetry: CLISocketSentryTelemetry?
    ) {
        let shortSessionID = String(sessionId.prefix(12))
        let incomingValue = incoming?.logValue ?? "none"
        let existingValue = existing?.logValue ?? "none"
        codexResumeBindingLogger.notice(
            "Codex resume binding publish rejected reason=\(reason, privacy: .public) session=\(shortSessionID, privacy: .private(mask: .hash)) incoming=\(incomingValue, privacy: .public) existing=\(existingValue, privacy: .public)"
        )
        telemetry?.breadcrumb(
            "codex-resume-binding.publish-rejected",
            data: [
                "reason": reason,
                "incoming_provenance": incomingValue,
                "existing_provenance": existingValue,
                "has_session_id": !sessionId.isEmpty,
            ]
        )
    }
}
