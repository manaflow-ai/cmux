import Foundation

extension CMUXCLI {
    func isCmuxClaudeWrapper(at path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        let prefixData = data.prefix(512)
        guard let prefix = String(data: prefixData, encoding: .utf8) else { return false }
        return prefix.contains("cmux claude wrapper - injects hooks and session tracking")
    }

    func resolveExecutableInSearchPath(
        _ name: String,
        searchPath: String?,
        skip: ((String) -> Bool)? = nil
    ) -> String? {
        let entries = searchPath?.split(separator: ":").map(String.init) ?? []
        for entry in entries where !entry.isEmpty {
            let candidate = URL(fileURLWithPath: entry, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
                .path
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            if let skip, skip(candidate) { continue }
            return candidate
        }
        return nil
    }

    func resolveClaudeExecutable(searchPath: String?) -> String? {
        resolveExecutableInSearchPath(
            "claude",
            searchPath: searchPath,
            skip: { self.isCmuxClaudeWrapper(at: $0) }
        )
    }

    func resolveCodexExecutable(searchPath: String?) -> String? {
        resolveExecutableInSearchPath("codex", searchPath: searchPath)
    }

    func resolveGrokExecutable(searchPath: String?) -> String? {
        // Prefer GROK_HOME/bin/grok when set (matches the AgentHookDef configDirEnvOverride),
        // then the conventional ~/.grok/bin/grok symlink (what the installer creates),
        // then fall back to grok in PATH.
        if let grokHome = ProcessInfo.processInfo.environment["GROK_HOME"] {
            let candidate = URL(fileURLWithPath: grokHome)
                .appendingPathComponent("bin/grok", isDirectory: false)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        let userHomeCandidate = NSString(string: "~/.grok/bin/grok").expandingTildeInPath
        if FileManager.default.isExecutableFile(atPath: userHomeCandidate) {
            return userHomeCandidate
        }
        return resolveExecutableInSearchPath("grok", searchPath: searchPath)
    }

    func claudeTeamsHasExplicitTeammateMode(commandArgs: [String]) -> Bool {
        commandArgs.contains { arg in
            arg == "--teammate-mode" || arg.hasPrefix("--teammate-mode=")
        }
    }

    func claudeTeamsLaunchArguments(commandArgs: [String]) -> [String] {
        guard !claudeTeamsHasExplicitTeammateMode(commandArgs: commandArgs) else {
            return commandArgs
        }
        return ["--teammate-mode", "auto"] + commandArgs
    }
}
