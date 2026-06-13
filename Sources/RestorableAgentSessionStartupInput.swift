import Foundation

/// Startup-input funnel for resuming and forking restorable agent sessions:
/// every entrypoint that launches `<agent> --resume/--fork` in a terminal goes
/// through here, so launch-time side effects (like Claude transcript seeding)
/// live in one place.
extension SessionRestorableAgentSnapshot {
    /// Claude scopes `--resume <id>` lookups to `projects/<encoded-cwd>/`, so a
    /// resume or fork launched in a different directory than the session's
    /// origin needs the transcript seeded there first
    /// (https://github.com/manaflow-ai/cmux/issues/5941). Runs at launch time,
    /// right before the startup input is handed to the terminal.
    private func seedClaudeTranscriptIfNeeded(fileManager: FileManager) {
        guard kind == .claude,
              let targetWorkingDirectory = workingDirectory ?? launchCommand?.workingDirectory else {
            return
        }
        ClaudeSessionTranscriptSeeder.seedIfNeeded(
            sessionId: sessionId,
            targetWorkingDirectory: targetWorkingDirectory,
            configDirCandidates: ClaudeSessionTranscriptSeeder.defaultConfigDirCandidates(
                launchEnvironment: launchCommand?.environment),
            fileManager: fileManager
        )
    }

    func resumeStartupInput(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        allowLauncherScript: Bool = true,
        allowOversizedInlineInput: Bool = false
    ) -> String? {
        seedClaudeTranscriptIfNeeded(fileManager: fileManager)
        return startupInput(
            command: resumeCommand,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory,
            allowLauncherScript: allowLauncherScript,
            allowOversizedInlineInput: allowOversizedInlineInput
        )
    }

    func resumeStartupCommand(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> String? {
        seedClaudeTranscriptIfNeeded(fileManager: fileManager)
        guard let command = resumeCommand,
              let scriptURL = AgentResumeScriptStore.writeLauncherScript(
                  command: command,
                  kind: kind,
                  sessionId: sessionId,
                  fileManager: fileManager,
                  temporaryDirectory: temporaryDirectory,
                  returnToLoginShell: true,
                  // Match the resume command's own cd: agents with an `.ignore` cwd policy resume from
                  // the current directory (no cd), so the post-exit shell must not force the launch dir.
                  workingDirectory: registration?.cwd == .ignore
                      ? nil
                      : (workingDirectory ?? launchCommand?.workingDirectory)
              ) else {
            return nil
        }
        return "/bin/zsh \(TerminalStartupShellQuoting.singleQuoted(scriptURL.path))"
    }

    func forkStartupInput(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        allowLauncherScript: Bool = true
    ) -> String? {
        seedClaudeTranscriptIfNeeded(fileManager: fileManager)
        return startupInput(
            command: forkCommand,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory,
            allowLauncherScript: allowLauncherScript
        )
    }

    private func startupInput(
        command: String?,
        fileManager: FileManager,
        temporaryDirectory: URL,
        allowLauncherScript: Bool = true,
        allowOversizedInlineInput: Bool = false
    ) -> String? {
        guard let command else { return nil }
        let inlineInput = command + "\n"
        guard inlineInput.utf8.count > Self.maxInlineStartupInputBytes else {
            return inlineInput
        }
        guard !allowOversizedInlineInput else {
            return inlineInput
        }
        guard allowLauncherScript else { return nil }
        guard let scriptURL = AgentResumeScriptStore.writeLauncherScript(
            command: command,
            kind: kind,
            sessionId: sessionId,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        ) else {
            return nil
        }

        let scriptInput = "/bin/zsh \(TerminalStartupShellQuoting.singleQuoted(scriptURL.path))\n"
        return scriptInput.utf8.count <= Self.maxInlineStartupInputBytes ? scriptInput : nil
    }
}

private enum AgentResumeScriptStore {
    private static let directoryName = "cmux-agent-resume"
    private static let scriptTTL: TimeInterval = 24 * 60 * 60

    static func writeLauncherScript(
        command: String,
        kind: RestorableAgentKind,
        sessionId: String,
        fileManager: FileManager,
        temporaryDirectory: URL,
        returnToLoginShell: Bool = false,
        workingDirectory: String? = nil
    ) -> URL? {
        let directoryURL = temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            pruneOldScripts(in: directoryURL, fileManager: fileManager)

            let safeSessionPrefix = sessionId
                .prefix(12)
                .map { character -> Character in
                    character.isLetter || character.isNumber || character == "-" ? character : "_"
                }
            let scriptURL = directoryURL.appendingPathComponent(
                "\(kind.rawValue)-\(String(safeSessionPrefix))-\(UUID().uuidString).zsh",
                isDirectory: false
            )
            var lines = [
                "#!/bin/zsh",
                "rm -f -- \"$0\" 2>/dev/null || true"
            ]
            if returnToLoginShell {
                lines.append(contentsOf: TerminalStartupReturnShellScript.commandThenReturnLines(
                    command: command,
                    workingDirectory: workingDirectory
                ))
            } else {
                lines.append(command)
            }
            let contents = lines.joined(separator: "\n") + "\n"
            try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scriptURL.path)
            return scriptURL
        } catch {
            return nil
        }
    }

    private static func pruneOldScripts(in directoryURL: URL, fileManager: FileManager) {
        guard let scriptURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-scriptTTL)
        for scriptURL in scriptURLs where scriptURL.pathExtension == "zsh" {
            let values = try? scriptURL.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? fileManager.removeItem(at: scriptURL)
            }
        }
    }
}
