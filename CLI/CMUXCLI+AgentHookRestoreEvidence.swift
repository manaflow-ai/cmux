import Foundation
import CMUXAgentLaunch

extension CMUXCLI {
    private static let codexPermissionEvidenceChunkBytes = 64 * 1024

    private func codexLaunchHasExplicitPermissions(_ launchCommand: AgentHookLaunchCommandRecord?) -> Bool {
        guard let launchCommand,
              AgentLaunchCaptureTrust.launcherDescribesKind(launchCommand.launcher, kind: "codex") else {
            return false
        }
        let arguments = launchCommand.arguments
        for (index, argument) in arguments.enumerated() {
            if [
                "--yolo",
                "--full-auto",
                "--dangerously-bypass-approvals-and-sandbox",
                "-a",
                "--ask-for-approval",
                "-s",
                "--sandbox",
            ].contains(argument) {
                return true
            }
            if argument.hasPrefix("--ask-for-approval=") || argument.hasPrefix("--sandbox=") {
                return true
            }
            if argument == "-c" || argument == "--config",
               index + 1 < arguments.count,
               codexConfigOverridesPermissions(arguments[index + 1]) {
                return true
            }
            if argument.hasPrefix("-c=") || argument.hasPrefix("--config=") {
                let components = argument.split(
                    separator: "=",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                if components.count == 2,
                   codexConfigOverridesPermissions(String(components[1])) {
                    return true
                }
            }
        }
        return false
    }

    private func codexConfigOverridesPermissions(_ value: String) -> Bool {
        let key = value.split(separator: "=", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key == "approval_policy" || key == "sandbox_mode"
    }
    func agentHookSessionHasDurableResumeEvidence(
        kind: String,
        launchCommand: AgentHookLaunchCommandRecord?
    ) -> Bool {
        guard normalizedHookValue(launchCommand?.source)?.lowercased() != "rejected" else { return false }
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

    func preferredAgentHookResumeLaunchCommand(
        kind: String,
        current: AgentHookLaunchCommandRecord?,
        mapped: ClaudeHookSessionRecord?,
        transcriptPath: String? = nil,
        currentPID: Int? = nil
    ) -> AgentHookLaunchCommandRecord? {
        if normalizedHookValue(current?.source)?.lowercased() == "rejected" {
            return current
        }
        if kind == "codex",
           let currentPID,
           currentPID == mapped?.pid,
           !codexLaunchHasExplicitPermissions(current),
           codexLaunchHasExplicitPermissions(mapped?.launchCommand) {
            return mapped?.launchCommand
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
            transcriptPath: transcriptPath
        )
    }

    func preferredAgentHookResumeWorkingDirectory(
        kind: String,
        current: AgentHookLaunchCommandRecord?,
        currentCwd: String?,
        mapped: ClaudeHookSessionRecord?
    ) -> String? {
        if normalizedHookValue(current?.source)?.lowercased() == "rejected" {
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

    func agentHookMappedSessionHasDurableTargetEvidence(
        kind: String,
        mapped: ClaudeHookSessionRecord?
    ) -> Bool {
        guard let mapped else { return false }
        guard normalizedHookValue(mapped.launchCommand?.source)?.lowercased() != "rejected" else { return false }
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
        transcriptPath: String?
    ) -> AgentHookLaunchCommandRecord? {
        guard var launchCommand else { return nil }
        guard !codexLaunchHasExplicitPermissions(launchCommand),
              let capturedAt = launchCommand.capturedAt,
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
        launchCommand.arguments.append(contentsOf: permissionArguments)
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
        let sandboxMode = (payload["sandbox_policy"] as? [String: Any]).flatMap {
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
        return arguments.isEmpty ? nil : arguments
    }
}
