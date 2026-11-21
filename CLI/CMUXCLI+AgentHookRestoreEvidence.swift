import Foundation
import CMUXAgentLaunch

extension CMUXCLI {
    /// Reports whether a captured Codex launch explicitly sets approval, sandbox or networking.
    private func codexLaunchHasExplicitPermissions(_ launchCommand: AgentHookLaunchCommandRecord?) -> Bool {
        CodexResumePermissionPolicy().hasExplicitPermissions(in: launchCommand)
    }

    /// Whether an OMP hook has no launch candidate to publish or invalidate.
    ///
    /// PID-only diagnostics describe the hook's dispatch context, not a
    /// replacement executable. Preserve an existing binding in that case, but
    /// never synthesize a bare `omp` command from the missing capture.
    func ompLaunchCaptureIsUnavailable(
        _ launchCommand: AgentHookLaunchCommandRecord?
    ) -> Bool {
        guard let launchCommand,
              launchCommand.arguments.isEmpty,
              normalizedHookValue(launchCommand.executablePath) == nil else {
            return false
        }
        switch launchCommand.rejectionReason {
        case .some(.argvUnavailable),
             .some(.nativeProcessDoesNotDescribeKind),
             .some(.argvLooksLikeShellWrapper):
            return true
        default:
            return false
        }
    }

    func agentHookSessionHasDurableResumeEvidence(
        kind: String,
        launchCommand: AgentHookLaunchCommandRecord?
    ) -> Bool {
        guard launchCommand?.isRejectedCapture != true else { return false }
        if kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "omp" {
            return AgentLaunchCaptureTrust.ompLaunchHasDurableResumeEvidence(launchCommand)
        }
        guard kind == "codex" else { return true }
        guard let launchCommand else { return true }
        if normalizedHookValue(launchCommand.environment?["CODEX_HOME"]) != nil {
            return true
        }
        if normalizedHookValue(launchCommand.source)?.lowercased() == "default" { return true }
        guard !launchCommand.arguments.isEmpty else { return false }
        let source = normalizedHookValue(launchCommand.source)?.lowercased()
        if source == "environment", codexLaunchEnvironmentIsWeak(launchCommand.environment) {
            return false
        }
        switch source {
        case nil, "environment", "process":
            return true
        default:
            return false
        }
    }

    /// The launch record a hook should publish for resume, with the session's external launcher
    /// preserved.
    ///
    /// Selection has several early exits (a rejected capture, the codex permission-evidence branch),
    /// and the external launcher is a property of the session rather than of whichever record wins,
    /// so preservation wraps the whole selection instead of sitting on one path. Ancestor detection
    /// can miss on a later hook once the launcher process is gone; a record that lost the id must
    /// never erase it. #10494
    func preferredAgentHookResumeLaunchCommand(
        kind: String,
        current: AgentHookLaunchCommandRecord?,
        mapped: ClaudeHookSessionRecord?,
        transcriptPath: String? = nil,
        currentPID: Int? = nil
    ) async -> AgentHookLaunchCommandRecord? {
        guard ProcessInfo.processInfo.environment["CMUX_AGENT_HOOK_RELAY_ORIGIN"] != "1" else {
            return nil
        }
        return await selectedAgentHookResumeLaunchCommand(
            kind: kind,
            current: current,
            mapped: mapped,
            transcriptPath: transcriptPath,
            currentPID: currentPID
        )?.preservingExternalLauncher(from: [current, mapped?.launchCommand])
    }

    /// Selects current or persisted launch evidence before repairing eligible Codex permissions.
    ///
    /// Rejected captures may use only a trusted same-kind fallback. A same-process mapped
    /// capture can retain explicit permissions that are absent from the current capture.
    ///
    /// - Parameters:
    ///   - kind: Agent kind whose resume command is being published.
    ///   - current: Launch evidence from the current hook observation.
    ///   - mapped: Previously persisted session evidence, when available.
    ///   - transcriptPath: Optional transcript used to recover missing Codex permissions.
    ///   - currentPID: Observed process identity used to corroborate mapped evidence.
    /// - Returns: Selected launch metadata, a retained rejection, or nil when no launch should be published.
    private func selectedAgentHookResumeLaunchCommand(
        kind: String,
        current: AgentHookLaunchCommandRecord?,
        mapped: ClaudeHookSessionRecord?,
        transcriptPath: String?,
        currentPID: Int?
    ) async -> AgentHookLaunchCommandRecord? {
        let ompCaptureUnavailable = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "omp"
            && ompLaunchCaptureIsUnavailable(current)
        if current?.isRejectedCapture == true || ompCaptureUnavailable {
            if let preserved = mappedLaunchAfterRejectedCapture(kind: kind, current: current, mapped: mapped) {
                return kind == "codex"
                    ? await repairedCodexLaunchCommand(
                        preserved, transcriptPath: transcriptPath, observedAt: current?.capturedAt
                    )
                    : preserved
            }
            return current
        }
        if kind == "codex",
           let currentPID,
           currentPID == mapped?.pid,
           !codexLaunchHasExplicitPermissions(current),
           codexLaunchHasExplicitPermissions(mapped?.launchCommand) {
            return await repairedCodexLaunchCommand(
                mapped?.launchCommand, transcriptPath: transcriptPath, observedAt: current?.capturedAt
            )
        }
        let selected: AgentHookLaunchCommandRecord? = {
            let currentSource = normalizedHookValue(current?.source)?.lowercased()
            if let current,
               currentSource != "default",
               agentHookSessionHasDurableResumeEvidence(kind: kind, launchCommand: current) {
                return current
            }
            if let mappedLaunchCommand = mapped?.launchCommand,
               agentHookSessionHasDurableResumeEvidence(kind: kind, launchCommand: mappedLaunchCommand) {
                return mappedLaunchCommand
            }
            if let current = replaySafeCodexLaunchCommand(kind: kind, launchCommand: current) {
                return current
            }
            if agentHookMappedSessionHasDurableTargetEvidence(kind: kind, mapped: mapped),
               let mapped = replaySafeCodexLaunchCommand(kind: kind, launchCommand: mapped?.launchCommand) {
                return mapped
            }
            if let current,
               currentSource == "default",
               agentHookSessionHasDurableResumeEvidence(kind: kind, launchCommand: current) {
                return current
            }
            if agentHookMappedSessionHasDurableTargetEvidence(kind: kind, mapped: mapped) {
                return nil
            }
            return current ?? mapped?.launchCommand
        }()
        guard kind == "codex" else { return selected }
        return await repairedCodexLaunchCommand(
            selected,
            transcriptPath: transcriptPath,
            observedAt: current?.capturedAt
        )
    }



    func preferredAgentHookResumeWorkingDirectory(
        kind: String,
        current: AgentHookLaunchCommandRecord?,
        currentCwd: String?,
        mapped: ClaudeHookSessionRecord?
    ) -> String? {
        guard ProcessInfo.processInfo.environment["CMUX_AGENT_HOOK_RELAY_ORIGIN"] != "1" else {
            return nil
        }
        let ompCaptureUnavailable = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "omp"
            && ompLaunchCaptureIsUnavailable(current)
        if current?.isRejectedCapture == true || ompCaptureUnavailable {
            if mappedLaunchAfterRejectedCapture(kind: kind, current: current, mapped: mapped) != nil {
                return mapped?.cwd ?? currentCwd
            }
            return currentCwd ?? mapped?.cwd
        }
        let currentSource = normalizedHookValue(current?.source)?.lowercased()
        if let current, currentSource != "default", agentHookSessionHasDurableResumeEvidence(kind: kind, launchCommand: current) {
            return currentCwd ?? mapped?.cwd
        }
        if let launchCommand = mapped?.launchCommand,
           agentHookSessionHasDurableResumeEvidence(kind: kind, launchCommand: launchCommand) {
            return mapped?.cwd ?? currentCwd
        }
        if agentHookMappedSessionHasDurableTargetEvidence(kind: kind, mapped: mapped) {
            return mapped?.cwd ?? currentCwd
        }
        return currentCwd ?? mapped?.cwd
    }

    private func mappedLaunchAfterRejectedCapture(
        kind: String,
        current: AgentHookLaunchCommandRecord?,
        mapped: ClaudeHookSessionRecord?
    ) -> AgentHookLaunchCommandRecord? {
        guard let rejectionReason = current?.rejectionReason,
              mappedLaunchFallbackIsSafe(for: rejectionReason),
              let mappedLaunch = mapped?.launchCommand,
              !mappedLaunch.isRejectedCapture,
              AgentLaunchCaptureTrust.launcherDescribesKind(mappedLaunch.launcher, kind: kind),
              !AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(mappedLaunch.arguments),
              agentHookSessionHasDurableResumeEvidence(kind: kind, launchCommand: mappedLaunch) else {
            return nil
        }
        return mappedLaunch
    }

    private func mappedLaunchFallbackIsSafe(
        for rejectionReason: AgentLaunchCaptureRejectionReason
    ) -> Bool {
        rejectionReason == .launcherDoesNotDescribeKind
            || rejectionReason == .nativeProcessDoesNotDescribeKind
            || rejectionReason == .argvLooksLikeShellWrapper
            || rejectionReason == .argvUnavailable
            || rejectionReason == .argvDecodeFailed
    }

    func agentHookMappedSessionHasDurableTargetEvidence(
        kind: String,
        mapped: ClaudeHookSessionRecord?
    ) -> Bool {
        guard let mapped else { return false }
        guard mapped.launchCommand?.isRejectedCapture != true else { return false }
        guard kind == "codex" else { return true }
        if mapped.isRestorable == true { return true }
        if let transcriptPath = normalizedHookValue(mapped.transcriptPath),
           FileManager.default.fileExists(atPath: (transcriptPath as NSString).expandingTildeInPath) {
            return true
        }
        guard let launchCommand = mapped.launchCommand else { return false }
        if normalizedHookValue(launchCommand.environment?["CODEX_HOME"]) != nil { return true }
        if normalizedHookValue(launchCommand.source)?.lowercased() == "default" { return true }
        guard !launchCommand.arguments.isEmpty else { return false }
        let source = normalizedHookValue(launchCommand.source)?.lowercased()
        if source == "environment", codexLaunchEnvironmentIsWeak(launchCommand.environment) {
            return false
        }
        switch source {
        case nil, "environment", "process":
            return true
        default:
            return false
        }
    }

    private func codexLaunchEnvironmentIsWeak(_ environment: [String: String]?) -> Bool {
        normalizedHookValue(environment?["CODEX_HOME"]) == nil
            && (normalizedHookValue(environment?["ANTHROPIC_BASE_URL"]) != nil
                || normalizedHookValue(environment?["CLAUDE_CONFIG_DIR"]) != nil)
    }

    /// A same-kind launch capture can inherit Claude account-selection environment from the
    /// terminal without making its sanitized Codex flags unsafe to replay. Keep those flags while
    /// dropping every identity-bearing part of the weak capture, so restore uses the current Codex
    /// executable and hook cwd instead of an inherited executable, environment, or launch cwd.
    private func replaySafeCodexLaunchCommand(
        kind: String,
        launchCommand: AgentHookLaunchCommandRecord?
    ) -> AgentHookLaunchCommandRecord? {
        guard kind == "codex",
              var launchCommand,
              normalizedHookValue(launchCommand.source)?.lowercased() == "environment",
              normalizedHookValue(launchCommand.launcher)?.lowercased() == "codex",
              !launchCommand.arguments.isEmpty,
              codexLaunchEnvironmentIsWeak(launchCommand.environment) else {
            return nil
        }
        launchCommand.executablePath = nil
        launchCommand.arguments[0] = "codex"
        launchCommand.workingDirectory = nil
        launchCommand.environment = nil
        return launchCommand
    }

    /// Recovers missing Codex permission fields from bounded, actor-isolated transcript evidence.
    ///
    /// Complete explicit policies and captures without usable timing or transcript metadata
    /// return unchanged. Recorded values never replace explicit launch arguments.
    ///
    /// - Parameters:
    ///   - launchCommand: Capture to repair, or nil when no launch was selected.
    ///   - transcriptPath: Optional path to the session's permission evidence.
    ///   - observedAt: Current hook time; takes precedence over the capture's older timestamp.
    /// - Returns: The original or repaired capture, preserving nil when no capture exists.
    private func repairedCodexLaunchCommand(
        _ launchCommand: AgentHookLaunchCommandRecord?,
        transcriptPath: String?,
        observedAt: TimeInterval? = nil
    ) async -> AgentHookLaunchCommandRecord? {
        guard let launchCommand else { return nil }
        guard !launchCommand.arguments.isEmpty else { return launchCommand }
        guard let capturedAt = observedAt ?? launchCommand.capturedAt,
              let transcriptPath = normalizedHookValue(transcriptPath) else {
            return launchCommand
        }
        let policy = CodexResumePermissionPolicy()
        guard policy.requiresTranscriptEvidence(for: launchCommand) else { return launchCommand }
        return policy.repairing(launchCommand, with: await CodexResumePermissionEvidenceReader().permissionArguments(
            transcriptPath: transcriptPath,
            before: capturedAt
        ))
    }

}
