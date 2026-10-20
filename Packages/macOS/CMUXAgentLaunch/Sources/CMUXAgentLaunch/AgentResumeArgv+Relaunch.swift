import Foundation

extension AgentResumeArgv {
    /// Builds a sanitized fresh-launch argv for a built-in relaunch-only agent.
    ///
    /// Relaunch-only agents do not have a session identifier or a resume verb.
    /// Their captured interactive command is replayed to restore the tool and
    /// model selection, while the upstream conversation starts fresh.
    ///
    /// - Parameters:
    ///   - kind: The built-in agent kind.
    ///   - executablePath: The captured executable path, if any.
    ///   - arguments: Captured argv, including the executable as element zero.
    /// - Returns: Sanitized launch argv, or `nil` for unsupported or unsafe input.
    public func builtInRelaunchKind(
        kind: String,
        executablePath: String?,
        arguments: [String]
    ) -> [String]? {
        guard kind == "ollama" else { return nil }
        let capturedExecutable = arguments.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = normalizedRelaunchValue(executablePath)
            ?? normalizedRelaunchValue(capturedExecutable)
            ?? "ollama"
        let capturedTail = arguments.isEmpty ? [] : Array(arguments.dropFirst())
        return AgentLaunchSanitizer.sanitizedLaunchArguments(
            [executable] + capturedTail,
            launcher: "",
            fallbackKind: kind
        )
    }

    private func normalizedRelaunchValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
