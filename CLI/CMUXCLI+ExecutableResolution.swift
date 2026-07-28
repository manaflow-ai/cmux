import CMUXAgentLaunch
import Darwin
import Foundation

extension CMUXCLI {
    func missingProviderExecutableMessage(displayName: String, executableName: String) -> String {
        let format = String(
            localized: "agentSession.error.missingProviderExecutable",
            defaultValue: "%@ was not found. Install it and make sure \"%@\" is available on PATH."
        )
        return String(format: format, displayName, executableName)
    }

    func isBundledProviderExecutable(at path: String) -> Bool {
        let candidate = URL(fileURLWithPath: path, isDirectory: false)
            .standardizedFileURL
            .path
        if isCmuxAppBundleResourceBinChild(candidate) {
            return true
        }
        guard let bundledBinDirectory = bundledProviderBinDirectory() else { return false }
        return candidate.hasPrefix(bundledBinDirectory + "/")
    }

    func isCmuxClaudeWrapper(at path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        let prefixData = data.prefix(512)
        guard let prefix = String(data: prefixData, encoding: .utf8) else { return false }
        return prefix.contains("cmux claude wrapper - injects hooks and session tracking")
    }

    func isCmuxClaudeCommandShim(at path: String) -> Bool {
        let candidate = URL(fileURLWithPath: path, isDirectory: false)
            .standardizedFileURL
            .path
        let environment = ProcessInfo.processInfo.environment
        let shimPaths = [
            environment["CMUX_CLAUDE_WRAPPER_SHIM"],
        ]
        for shimPath in shimPaths {
            guard let shimPath else { continue }
            let standardizedShim = URL(fileURLWithPath: shimPath, isDirectory: false)
                .standardizedFileURL
                .path
            if candidate == standardizedShim {
                return true
            }
        }

        let shimRoots: [String?] = [
            environment["CMUX_CLAUDE_WRAPPER_SHIM_ROOT"],
            URL(fileURLWithPath: environment["TMPDIR"] ?? NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("cmux-cli-shims", isDirectory: true)
                .standardizedFileURL
                .path,
            "/tmp/cmux-cli-shims",
        ]
        for shimRoot in shimRoots {
            guard let shimRoot else { continue }
            let standardizedRoot = URL(fileURLWithPath: shimRoot, isDirectory: true)
                .standardizedFileURL
                .path
            if candidate.hasPrefix(standardizedRoot + "/") {
                return true
            }
        }
        return false
    }

    func resolveExecutableInSearchPath(
        _ name: String,
        searchPath: String?,
        skip: ((String) -> Bool)? = nil
    ) -> String? {
        let entries = providerExecutableSearchDirectories(searchPath: searchPath)
        for entry in entries where !entry.isEmpty {
            let candidate = URL(fileURLWithPath: entry, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
                .path
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            guard !isBundledProviderExecutable(at: candidate) else { continue }
            if let skip, skip(candidate) { continue }
            return candidate
        }
        return nil
    }

    func resolveClaudeExecutable(configuredCandidates: [String?], searchPath: String?) -> String? {
        for raw in configuredCandidates {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isExecutableFile(atPath: trimmed),
                  !isBundledProviderExecutable(at: trimmed),
                  !isCmuxClaudeCommandShim(at: trimmed),
                  !isCmuxClaudeWrapper(at: trimmed) else { continue }
            return URL(fileURLWithPath: trimmed, isDirectory: false).standardizedFileURL.path
        }

        return resolveClaudeExecutable(searchPath: searchPath)
    }

    func resolveClaudeExecutable(searchPath: String?) -> String? {
        resolveExecutableInSearchPath(
            "claude",
            searchPath: searchPath,
            skip: { self.isCmuxClaudeCommandShim(at: $0) || self.isCmuxClaudeWrapper(at: $0) }
        )
    }

    func resolveCodexExecutable(searchPath: String?) -> String? {
        resolveExecutableInSearchPath("codex", searchPath: searchPath)
    }

    func providerExecutableSearchPath(searchPath: String?, includingExecutableAt executablePath: String? = nil) -> String {
        var directories = providerExecutableSearchDirectories(searchPath: searchPath)
        if let executablePath {
            let executableDirectory = URL(fileURLWithPath: executablePath, isDirectory: false)
                .standardizedFileURL
                .deletingLastPathComponent()
                .path
            directories.removeAll { $0 == executableDirectory }
            directories.insert(executableDirectory, at: 0)
        }
        return directories.joined(separator: ":")
    }

    func claudeTeamsHasExplicitTeammateMode(commandArgs: [String]) -> Bool {
        commandArgs.contains { arg in
            arg == "--teammate-mode" || arg.hasPrefix("--teammate-mode=")
        }
    }

    /// Whether the user passed `--dangerously-skip-permissions` as a real Claude
    /// *option* (not as prompt text). This gates a trust-boundary decision, so it
    /// must not treat a token that lands in the prompt as an opt-in: a claude-teams
    /// prompt can legitimately contain `--dangerously-skip-permissions` after a
    /// prompt-boundary option (`--tmux`), after `--`, or as another option's value.
    /// Defer to the claude-teams launch parser's option/prompt-boundary rules, which
    /// match how Claude itself treats those positions (including options that follow
    /// the prompt positional).
    func claudeTeamsHasDangerousSkipPermissions(commandArgs: [String]) -> Bool {
        AgentLaunchSanitizer.claudeTeamsLaunchHasOption(
            "--dangerously-skip-permissions",
            args: commandArgs
        )
    }

    /// Environment the lead `claude` is launched with. CLAUDE_CODE_SANDBOXED skips
    /// Claude Code's interactive "Do you trust this folder?" gate so the unattended
    /// lead/teammate panes don't deadlock on it (#6447). That gate is a real safety
    /// boundary — running `claude` in an untrusted checkout — so it is only waived
    /// when the user has already opted into skipping safety prompts with
    /// `--dangerously-skip-permissions`. Without that flag the trust prompt is left
    /// in place and the user vets the directory normally.
    ///
    /// The opt-in decision is made here, once, by an exact argv check, and recorded
    /// in `CMUX_CLAUDE_TEAMS_SANDBOXED` so teammate respawns (which run as a separate
    /// `cmux __tmux-compat` process and cannot see this argv) re-apply the same
    /// decision without re-deriving it from untrusted command text — see
    /// `tmuxClaudeTeamsRespawnEnvironment()`.
    func claudeTeamsExtraEnvVars(commandArgs: [String]) -> [(key: String, value: String)] {
        var vars: [(key: String, value: String)] = [
            (key: "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", value: "1"),
        ]
        if claudeTeamsHasDangerousSkipPermissions(commandArgs: commandArgs) {
            vars.append((key: "CLAUDE_CODE_SANDBOXED", value: "1"))
            vars.append((key: "CMUX_CLAUDE_TEAMS_SANDBOXED", value: "1"))
        }
        return vars
    }

    func claudeTeamsLaunchArguments(commandArgs: [String]) -> [String] {
        guard !claudeTeamsHasExplicitTeammateMode(commandArgs: commandArgs) else {
            return commandArgs
        }
        return ["--teammate-mode", "auto"] + commandArgs
    }

    func claudeTeamsHasExplicitSystemPrompt(commandArgs: [String]) -> Bool {
        commandArgs.contains { arg in
            arg == "--system-prompt" || arg.hasPrefix("--system-prompt=")
                || arg == "--system-prompt-file" || arg.hasPrefix("--system-prompt-file=")
                || arg == "--append-system-prompt" || arg.hasPrefix("--append-system-prompt=")
                || arg == "--append-system-prompt-file" || arg.hasPrefix("--append-system-prompt-file=")
        }
    }

    /// The whole point of `cmux claude-teams` is "just start a team." Claude Code's
    /// Task tool only opens a teammate in its own split pane when it is called with
    /// a `name`; without a name it runs an in-process subagent (no pane). Left to a
    /// bare prompt the lead tends to use the nameless form — or stops to ask "demo
    /// *what*?" — so a plain `cmux claude-teams "make a demo team with 5 subagents"`
    /// produced no panes. Append a small system-prompt nudge that steers the lead to
    /// named, split-pane teammates for team/parallel requests so no elaborate prompt
    /// is needed. Kept out of `claudeTeamsLaunchArguments` (and thus the exported
    /// restore command) so that stays canonical; restore re-invokes `cmux
    /// claude-teams`, which re-applies the nudge. Skipped when the user supplies
    /// their own system prompt.
    var claudeTeamsTeamSpawnGuidance: String {
        """
        You are Claude Code running inside cmux, started with `cmux claude-teams`. \
        Agent teams are enabled and every NAMED teammate opens in its own split \
        pane. When the user asks you to start a team, demo teams, or run several \
        subagents/teammates in parallel, spawn them as named teammates: make one \
        Task tool call per teammate, each with a distinct `name` (a short role), all \
        in a single message so they run concurrently in their own split panes. \
        Prefer named teammates over in-process subagents for any team or \
        parallel-agent request. If the user asks for an open-ended demo such as \
        "make a demo team with 5 subagents" without naming a topic, do not ask which \
        feature — pick that many sensible roles and spawn them right away.
        """
    }

    /// The live `execv` argv for the lead: the canonical launch arguments plus the
    /// split-pane-teammate system-prompt nudge (see `claudeTeamsTeamSpawnGuidance`).
    /// The nudge is inserted right after a leading `--teammate-mode <value>` pair so
    /// callers/tests that expect that pair first keep working.
    func claudeTeamsExecArguments(commandArgs: [String]) -> [String] {
        let base = claudeTeamsLaunchArguments(commandArgs: commandArgs)
        guard !claudeTeamsHasExplicitSystemPrompt(commandArgs: commandArgs) else {
            return base
        }
        let nudge = ["--append-system-prompt", claudeTeamsTeamSpawnGuidance]
        if base.count >= 2, base[0] == "--teammate-mode" {
            return Array(base[0..<2]) + nudge + Array(base[2...])
        }
        return nudge + base
    }

    func clearInheritedClaudeLaunchEnvironment() {
        for key in ClaudeSessionEnvironmentPolicy().inheritedIndependentLaunchKeys {
            unsetenv(key)
        }
    }

    private func providerExecutableSearchDirectories(searchPath: String?) -> [String] {
        var directories = searchPath?.split(separator: ":").map(String.init) ?? []
        let environment = ProcessInfo.processInfo.environment
        if let home = environment["HOME"], !home.isEmpty {
            directories.append(contentsOf: [
                "\(home)/.local/bin",
                "\(home)/.bun/bin",
                "\(home)/.nvm/current/bin",
                "\(home)/.volta/bin",
                "\(home)/.fnm/current/bin",
                "\(home)/.local/share/mise/shims",
                "\(home)/.asdf/shims",
                "\(home)/bin"
            ])
            directories.append(contentsOf: providerNodeVersionBinDirectories(root: "\(home)/.nvm/versions/node", suffix: "bin"))
            directories.append(contentsOf: providerNodeVersionBinDirectories(root: "\(home)/Library/Application Support/fnm/node-versions", suffix: "installation/bin"))
            directories.append(contentsOf: providerNodeVersionBinDirectories(root: "\(home)/.local/share/fnm/node-versions", suffix: "installation/bin"))
        }
        directories.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ])

        var seen: Set<String> = []
        return directories.compactMap { rawDirectory in
            let trimmed = rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let standardized = URL(fileURLWithPath: trimmed, isDirectory: true)
                .standardizedFileURL
                .path
            guard !isCmuxAppBundleResourceBinDirectory(standardized) else { return nil }
            guard seen.insert(standardized).inserted else { return nil }
            return standardized
        }
    }

    private func providerNodeVersionBinDirectories(root: String, suffix: String) -> [String] {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let versionURLs = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return versionURLs
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted(by: providerNodeVersionURLSortPrecedes)
            .map { versionURL in
                suffix.split(separator: "/").reduce(versionURL) { partial, component in
                    partial.appendingPathComponent(String(component), isDirectory: true)
                }.path
            }
    }

    private func providerNodeVersionURLSortPrecedes(_ lhs: URL, _ rhs: URL) -> Bool {
        let comparison = lhs.lastPathComponent.compare(
            rhs.lastPathComponent,
            options: [.caseInsensitive, .numeric]
        )
        if comparison != .orderedSame {
            return comparison == .orderedDescending
        }
        return lhs.path > rhs.path
    }

    private func bundledProviderBinDirectory() -> String? {
        guard let executableURL = resolvedExecutableURL()?.standardizedFileURL else {
            return nil
        }
        let directory = executableURL.deletingLastPathComponent().standardizedFileURL.path
        guard directory.hasSuffix("/Contents/Resources/bin") || directory.hasSuffix("/Resources/bin") else {
            return nil
        }
        return directory
    }

    private func isCmuxAppBundleResourceBinDirectory(_ path: String) -> Bool {
        cmuxAppBundleResourceBinComponentIndex(path).map { index in
            URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.pathComponents.count == index + 4
        } ?? false
    }

    private func isCmuxAppBundleResourceBinChild(_ path: String) -> Bool {
        cmuxAppBundleResourceBinComponentIndex(path).map { index in
            URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.pathComponents.count > index + 4
        } ?? false
    }

    private func cmuxAppBundleResourceBinComponentIndex(_ path: String) -> Int? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard components.count >= 4 else { return nil }
        for index in components.indices {
            guard components[index].hasSuffix(".app"),
                  components[index].lowercased().contains("cmux"),
                  components.indices.contains(index + 3),
                  components[index + 1] == "Contents",
                  components[index + 2] == "Resources",
                  components[index + 3] == "bin" else {
                continue
            }
            return index
        }
        return nil
    }
}
