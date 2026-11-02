import Foundation
import CoreFoundation
import CMUXAgentLaunch

extension CMUXCLI {
    private static let codexPermissionEvidenceChunkBytes = 64 * 1024

    private func codexLaunchHasExplicitPermissions(_ launchCommand: AgentHookLaunchCommandRecord?) -> Bool {
        let fields = codexLaunchPermissionFields(launchCommand)
        return fields.approval || fields.sandbox || fields.network
    }

    private func codexLaunchPermissionFields(
        _ launchCommand: AgentHookLaunchCommandRecord?
    ) -> (approval: Bool, sandbox: Bool, network: Bool, sandboxMode: String?) {
        guard let launchCommand,
              AgentLaunchCaptureTrust.launcherDescribesKind(launchCommand.launcher, kind: "codex") else {
            return (false, false, false, nil)
        }
        let arguments = launchCommand.arguments
        var approval = false
        var sandbox = false
        var network = false
        var sandboxFlag: String?
        var sandboxConfig: String?
        var fullAuto = false
        var bypass = false
        for (index, argument) in arguments.enumerated() {
            if argument == "--" { break }
            if ["--yolo", "--dangerously-bypass-approvals-and-sandbox"].contains(argument) {
                approval = true
                sandbox = true
                bypass = true
            }
            if argument == "--full-auto" {
                approval = true
                sandbox = true
                fullAuto = true
            }
            if argument == "-a" || argument == "--ask-for-approval"
                || argument.hasPrefix("--ask-for-approval=")
                || (argument.hasPrefix("-a") && argument.count > 2) {
                approval = true
            }
            if argument == "-s" || argument == "--sandbox" {
                sandbox = true
                if index + 1 < arguments.count { sandboxFlag = arguments[index + 1] }
            } else if argument.hasPrefix("--sandbox=") {
                sandbox = true
                sandboxFlag = String(argument.dropFirst("--sandbox=".count))
            } else if argument.hasPrefix("-s"), argument.count > 2 {
                sandbox = true
                sandboxFlag = String(argument.dropFirst(argument.hasPrefix("-s=") ? 3 : 2))
            }
            if let config = codexConfigOverride(in: arguments, at: index) {
                let parts = config.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let rawKey = parts.first else { continue }
                switch rawKey.trimmingCharacters(in: .whitespacesAndNewlines) {
                case "approval_policy":
                    approval = true
                case "sandbox_mode":
                    sandbox = true
                    if parts.count == 2 {
                        sandboxConfig = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    }
                case "sandbox_workspace_write", "sandbox_workspace_write.network_access":
                    // A parent TOML table is authoritative even when its exact
                    // networking field cannot be parsed safely here.
                    network = true
                default:
                    break
                }
            }
        }
        // Match Codex's flag-over-config precedence independently of argv order.
        let mode = bypass ? "danger-full-access"
            : sandboxFlag ?? (fullAuto ? "workspace-write" : sandboxConfig)
        return (approval, sandbox, network, mode)
    }

    private func codexConfigOverride(in arguments: [String], at index: Int) -> String? {
        let argument = arguments[index]
        if argument == "-c" || argument == "--config" {
            return index + 1 < arguments.count ? arguments[index + 1] : nil
        }
        for prefix in ["--config=", "-c=", "-c"] where argument.hasPrefix(prefix) {
            return String(argument.dropFirst(prefix.count))
        }
        return nil
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
    ) -> AgentHookLaunchCommandRecord? {
        guard ProcessInfo.processInfo.environment["CMUX_AGENT_HOOK_RELAY_ORIGIN"] != "1" else {
            return nil
        }
        return selectedAgentHookResumeLaunchCommand(
            kind: kind,
            current: current,
            mapped: mapped,
            transcriptPath: transcriptPath,
            currentPID: currentPID
        )?.preservingExternalLauncher(from: [current, mapped?.launchCommand])
    }

    private func selectedAgentHookResumeLaunchCommand(
        kind: String,
        current: AgentHookLaunchCommandRecord?,
        mapped: ClaudeHookSessionRecord?,
        transcriptPath: String?,
        currentPID: Int?
    ) -> AgentHookLaunchCommandRecord? {
        let ompCaptureUnavailable = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "omp"
            && ompLaunchCaptureIsUnavailable(current)
        if current?.isRejectedCapture == true || ompCaptureUnavailable {
            if let preserved = mappedLaunchAfterRejectedCapture(kind: kind, current: current, mapped: mapped) {
                return kind == "codex"
                    ? repairedCodexLaunchCommand(
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
            return repairedCodexLaunchCommand(
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
        return repairedCodexLaunchCommand(
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

    private func repairedCodexLaunchCommand(
        _ launchCommand: AgentHookLaunchCommandRecord?,
        transcriptPath: String?,
        observedAt: TimeInterval? = nil
    ) -> AgentHookLaunchCommandRecord? {
        guard var launchCommand else { return nil }
        guard !launchCommand.arguments.isEmpty else { return launchCommand }
        guard let capturedAt = observedAt ?? launchCommand.capturedAt,
              let transcriptPath = normalizedHookValue(transcriptPath) else {
            return launchCommand
        }
        let permissionArguments = codexPermissionArguments(
            transcriptPath: transcriptPath,
            before: capturedAt
        )
        guard !permissionArguments.isEmpty else {
            return launchCommand
        }
        let explicit = codexLaunchPermissionFields(launchCommand)
        let shortcut = permissionArguments.count == 1
            && ["--yolo", "--dangerously-bypass-approvals-and-sandbox"].contains(permissionArguments[0])
        if shortcut, !explicit.approval, !explicit.sandbox {
            launchCommand.arguments.append(contentsOf: permissionArguments)
            return launchCommand
        }
        func inferredValue(_ option: String) -> String? {
            guard let index = permissionArguments.firstIndex(of: option),
                  index + 1 < permissionArguments.count else { return nil }
            return permissionArguments[index + 1]
        }
        let approval = shortcut ? "never" : inferredValue("-a")
        let sandbox = shortcut ? "danger-full-access" : inferredValue("-s")
        if !explicit.approval, let approval {
            launchCommand.arguments.append(contentsOf: ["-a", approval])
        }
        if !explicit.sandbox, let sandbox {
            launchCommand.arguments.append(contentsOf: ["-s", sandbox])
        }
        let effectiveSandbox = explicit.sandbox ? explicit.sandboxMode : sandbox
        if !explicit.network, effectiveSandbox == "workspace-write",
           let network = permissionArguments.first(where: { $0.hasPrefix("sandbox_workspace_write.network_access=") }) {
            launchCommand.arguments.append(contentsOf: ["-c", network])
        }
        return launchCommand
    }

    private func codexPermissionArguments(
        transcriptPath: String,
        before capturedAt: TimeInterval
    ) -> [String] {
        let expandedPath = (transcriptPath as NSString).expandingTildeInPath
        guard let handle = FileHandle(forReadingAtPath: expandedPath) else { return [] }
        defer { try? handle.close() }
        guard let endOffset = try? handle.seekToEnd() else { return [] }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var offset = endOffset
        var pending = Data()
        while offset > 0 {
            let byteCount = min(UInt64(Self.codexPermissionEvidenceChunkBytes), offset)
            offset -= byteCount
            do {
                try handle.seek(toOffset: offset)
            } catch {
                return []
            }
            guard let chunk = try? handle.read(upToCount: Int(byteCount)) else { return [] }
            pending.insert(contentsOf: chunk, at: pending.startIndex)
            while let newline = pending.lastIndex(of: 0x0A) {
                let lineStart = pending.index(after: newline)
                let line = Data(pending[lineStart...])
                pending.removeSubrange(newline...)
                if let arguments = codexPermissionArguments(
                    from: line,
                    before: capturedAt,
                    formatter: formatter
                ) {
                    return arguments
                }
            }
        }
        return codexPermissionArguments(from: pending, before: capturedAt, formatter: formatter) ?? []
    }

    private func codexPermissionArguments(
        from line: Data,
        before capturedAt: TimeInterval,
        formatter: ISO8601DateFormatter
    ) -> [String]? {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "turn_context",
              let timestamp = object["timestamp"] as? String,
              let date = formatter.date(from: timestamp),
              date.timeIntervalSince1970 < capturedAt,
              let payload = object["payload"] as? [String: Any] else {
            return nil
        }
        let approvalPolicy = normalizedHookValue(payload["approval_policy"] as? String)
        let sandboxPolicy = payload["sandbox_policy"] as? [String: Any]
        let sandboxMode = sandboxPolicy.flatMap {
            normalizedHookValue($0["type"] as? String)
        }
        if approvalPolicy == "never", sandboxMode == "danger-full-access" {
            return ["--yolo"]
        }
        if approvalPolicy == "never", sandboxMode == "disabled" {
            return ["--dangerously-bypass-approvals-and-sandbox"]
        }
        var arguments: [String] = []
        if let approvalPolicy {
            arguments.append(contentsOf: ["-a", approvalPolicy])
        }
        if let sandboxMode,
           ["read-only", "workspace-write", "danger-full-access"].contains(sandboxMode) {
            arguments.append(contentsOf: ["-s", sandboxMode])
        }
        // JSON numbers also bridge to Bool. Replay only an actual recorded Boolean,
        // preserving both true and false without inventing a missing policy.
        if sandboxMode == "workspace-write",
           let networkAccess = sandboxPolicy?["network_access"] as? NSNumber,
           CFGetTypeID(networkAccess) == CFBooleanGetTypeID() {
            arguments.append(contentsOf: [
                "-c",
                "sandbox_workspace_write.network_access=\(networkAccess.boolValue ? "true" : "false")",
            ])
        }
        return arguments.isEmpty ? nil : arguments
    }
}
