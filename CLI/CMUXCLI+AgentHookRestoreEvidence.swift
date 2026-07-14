import Foundation
import CMUXAgentLaunch

enum CodexLaunchPermissionPolicy {
    static func hasExplicitArguments(_ launchCommand: AgentHookLaunchCommandRecord?) -> Bool {
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
               configOverridesPermissions(arguments[index + 1]) {
                return true
            }
            if argument.hasPrefix("-c=") || argument.hasPrefix("--config=") {
                let value = String(argument.split(separator: "=", maxSplits: 1)[1])
                if configOverridesPermissions(value) {
                    return true
                }
            }
        }
        return false
    }

    static func wouldDropExplicitArguments(
        existing: AgentHookLaunchCommandRecord?,
        incoming: AgentHookLaunchCommandRecord?
    ) -> Bool {
        hasExplicitArguments(existing) && !hasExplicitArguments(incoming)
    }

    private static func configOverridesPermissions(_ value: String) -> Bool {
        let key = value.split(separator: "=", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key == "approval_policy" || key == "sandbox_mode"
    }
}

extension CMUXCLI {
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
        mapped: ClaudeHookSessionRecord?
    ) -> AgentHookLaunchCommandRecord? {
        if normalizedHookValue(current?.source)?.lowercased() == "rejected" {
            return current
        }
        let mappedLaunchCommand = kind == "codex"
            ? repairedCodexLaunchCommand(mapped)
            : mapped?.launchCommand
        if kind == "codex",
           let current,
           let mappedLaunchCommand,
           !CodexLaunchPermissionPolicy.hasExplicitArguments(current),
           CodexLaunchPermissionPolicy.hasExplicitArguments(mappedLaunchCommand) {
            return mappedLaunchCommand
        }
        let currentSource = normalizedHookValue(current?.source)?.lowercased()
        if let current, currentSource != "default", agentHookSessionHasDurableResumeEvidence(kind: kind, launchCommand: current) {
            return current
        }
        if let launchCommand = mappedLaunchCommand,
           agentHookSessionHasDurableResumeEvidence(kind: kind, launchCommand: launchCommand) {
            return launchCommand
        }
        if let current, currentSource == "default", agentHookSessionHasDurableResumeEvidence(kind: kind, launchCommand: current) {
            return current
        }
        if agentHookMappedSessionHasDurableTargetEvidence(kind: kind, mapped: mapped) {
            return nil
        }
        return current ?? mappedLaunchCommand
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

    private func repairedCodexLaunchCommand(
        _ mapped: ClaudeHookSessionRecord?
    ) -> AgentHookLaunchCommandRecord? {
        guard let mapped, var launchCommand = mapped.launchCommand else { return nil }
        guard !CodexLaunchPermissionPolicy.hasExplicitArguments(launchCommand),
              let capturedAt = launchCommand.capturedAt,
              let transcriptPath = normalizedHookValue(mapped.transcriptPath),
              let permissionArguments = codexPermissionArguments(
                  transcriptPath: transcriptPath,
                  before: capturedAt
              ),
              !permissionArguments.isEmpty else {
            return launchCommand
        }
        launchCommand.arguments.append(contentsOf: permissionArguments)
        return launchCommand
    }

    private func codexPermissionArguments(
        transcriptPath: String,
        before capturedAt: TimeInterval
    ) -> [String]? {
        let expandedPath = (transcriptPath as NSString).expandingTildeInPath
        guard let handle = FileHandle(forReadingAtPath: expandedPath) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4 * 1024 * 1024) else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var approvalPolicy: String?
        var sandboxMode: String?
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "turn_context",
                  let timestamp = object["timestamp"] as? String,
                  let date = formatter.date(from: timestamp) else {
                continue
            }
            if date.timeIntervalSince1970 >= capturedAt {
                break
            }
            guard let payload = object["payload"] as? [String: Any] else { continue }
            if let value = normalizedHookValue(payload["approval_policy"] as? String) {
                approvalPolicy = value
            }
            if let sandbox = payload["sandbox_policy"] as? [String: Any],
               let value = normalizedHookValue(sandbox["type"] as? String) {
                sandboxMode = value
            }
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
