import CMUXAgentLaunch
import CmuxFoundation
import Foundation

extension CMUXCLI {
    /// Hidden wrapper helper. Exec preserves this native process identity, so
    /// every later hook can prove that its launch PID was not recycled.
    func emitCodexProcessIdentity(arguments: [String]) throws {
        guard arguments.count == 2,
              arguments[0] == "--pid",
              let pid = Int(arguments[1]),
              let identity = codexProcessStartIdentity(pid: pid) else {
            throw CLIError(
                message: "Usage: cmux hooks codex process-identity --pid <pid>"
            )
        }
        print(
            "\(identity.seconds):\(identity.microseconds)",
            terminator: ""
        )
    }

    /// Emit, NUL-separated to stdout, the exact codex arg list the wrapper must
    /// splice ahead of the user's args to enable + inject cmux's fire-and-forget
    /// hooks for one codex invocation. Returns the arg list:
    ///   --enable\0hooks\0--dangerously-bypass-hook-trust\0
    ///   -c\0hooks.SessionStart=[{hooks=[{type="command",command='''<ff>''',timeout=10000}]}]\0
    ///   -c\0hooks.UserPromptSubmit=...\0 ... (one `-c` pair per event)
    /// where `<ff>` is `codexFireAndForgetAgentHookShellCommand(...)` so each
    /// hook returns `{}` to codex instantly and backgrounds the real cmux call.
    /// Requires no live socket: pure string construction from the agent def.
    func emitCodexWrapperInjectArgs() throws {
        guard let codexDef = Self.agentDef(named: "codex") else {
            throw CLIError(message: "Codex hook integration is unavailable.")
        }
        // Prefer a #!/bin/sh SCRIPT FILE as the hook command over an inline shell
        // snippet. Some codex-compatible runtimes (subrouters, proxies) exec the
        // `command` string directly as a program instead of via a shell, so an
        // inline snippet fails with "No such file or directory (os error 2)". A
        // bare executable file path runs correctly whether the runtime execs it
        // directly or through a shell, and normal codex (which runs it via shell)
        // is unaffected. The scripts are env-driven and identical across
        // invocations, so they are written once into a cmux-owned dir (~/.cmux/
        // hooks), not the user's ~/.codex. Any write failure falls back to the
        // inline snippet so the working path can never regress.
        let hooksDir = Self.codexHookScriptsDirectory()
        var args: [String] = ["--enable", "hooks", "--dangerously-bypass-hook-trust"]
        for event in CodexHookInjectionSchema.current.events {
            let ff = Self.codexFireAndForgetAgentHookShellCommand(
                "cmux hooks codex \(event.cmuxSubcommand)", for: codexDef
            )
            let command: String
            if let scriptPath = hooksDir.flatMap({
                Self.writeCodexHookScript(subcommand: event.cmuxSubcommand, body: ff, in: $0)
            }), !scriptPath.contains("'''") {
                command = scriptPath
            } else {
                command = ff
            }
            // TOML multi-line literal string ('''...''') preserves bytes verbatim
            // and may contain single quotes, so the embedded `echo '{}'` / `sh -c
            // '...'` survive with no escaping. TOML forbids only a literal triple
            // single quote inside; guard against it (neither a path nor the
            // command ever has one).
            guard !command.contains("'''") else {
                throw CLIError(message: "Codex hook command contains a triple single quote and cannot be TOML-encoded.")
            }
            let toml = "hooks.\(event.agentEvent)=[{hooks=[{type=\"command\",command='''\(command)''',timeout=\(event.timeoutMs)}]}]"
            args.append("-c")
            args.append(toml)
        }
        emitNulSeparatedArguments(args)
    }

    /// Emit the invocation-only project trust override that must follow a
    /// `codex resume` subcommand. Codex accepts hook configuration as global
    /// arguments before `resume`, but resume project trust is parsed from the
    /// subcommand's argument scope and is ignored when prepended.
    func emitCodexWrapperResumeArgs() async {
        emitNulSeparatedArguments(await codexResumeTrustOverride())
    }

    private func emitNulSeparatedArguments(_ arguments: [String]) {
        // NUL-terminate each arg (trailing NUL after the last too) so a bash
        // `while IFS= read -r -d '' arg` loop captures every element including
        // the final one. A separator-only stream drops the unterminated last
        // arg at EOF.
        var out = Data()
        for arg in arguments {
            out.append(Data(arg.utf8))
            out.append(0)
        }
        FileHandle.standardOutput.write(out)
    }

    /// Returns a fail-closed, invocation-only project trust decision for an
    /// unattended Codex resume. Existing explicit cwd or repository decisions
    /// remain authoritative; an undecided project resumes as untrusted instead
    /// of blocking the restored pane on Codex's trust picker.
    private func codexResumeTrustOverride() async -> [String] {
        let environment = ProcessInfo.processInfo.environment
        guard let arguments = codexCapturedLaunchArguments(environment),
              let currentDirectory = normalizedHookValue(
                  environment["CMUX_AGENT_LAUNCH_CWD"]
              ) ?? normalizedHookValue(FileManager.default.currentDirectoryPath) else {
            return []
        }
        let policy = CodexResumeTrustPolicy()
        // Gate every subprocess behind a confirmed resume. Fresh Codex
        // launches only need the normal hook injection.
        guard
            let appServerConfigurationArguments = policy
                .appServerConfigurationArguments(arguments: arguments),
            let effectiveDirectory = policy.effectiveWorkingDirectory(
                arguments: arguments,
                currentDirectory: currentDirectory
            )
        else {
            return []
        }
        guard let projectDecisions = await codexEffectiveProjectDecisionPaths(
            environment: environment,
            appServerConfigurationArguments: appServerConfigurationArguments,
            currentDirectory: effectiveDirectory,
            policy: policy
        ) else {
            return []
        }
        let repository = await codexRepositoryDecisionRoots(
            currentDirectory: effectiveDirectory
        )
        guard repository.resolved else {
            return []
        }
        return policy.undecidedProjectOverride(
            arguments: arguments,
            currentDirectory: currentDirectory,
            repositoryRoots: repository.roots,
            effectiveProjectDecisionPaths: projectDecisions
        )
    }

    private func codexCapturedLaunchArguments(_ environment: [String: String]) -> [String]? {
        guard let raw = normalizedHookValue(environment["CMUX_AGENT_LAUNCH_ARGV_B64"]),
              let data = Data(base64Encoded: raw) else {
            return nil
        }
        var arguments = data.split(separator: 0, omittingEmptySubsequences: false)
        if arguments.last?.isEmpty == true {
            arguments.removeLast()
        }
        let decoded = arguments.compactMap { String(data: Data($0), encoding: .utf8) }
        return decoded.count == arguments.count ? decoded : nil
    }

    private func codexEffectiveProjectDecisionPaths(
        environment: [String: String],
        appServerConfigurationArguments: [String],
        currentDirectory: String,
        policy: CodexResumeTrustPolicy
    ) async -> Set<String>? {
        guard let executablePath = normalizedHookValue(
            environment["CMUX_AGENT_LAUNCH_EXECUTABLE"]
        ),
            executablePath.hasPrefix("/"),
            FileManager.default.isExecutableFile(atPath: executablePath),
            let requests = codexConfigReadRequests(
                currentDirectory: currentDirectory
            )
        else {
            return nil
        }

        let modelCatalogPath = codexModelsCachePath(environment: environment)
        let configurationPaths = codexConfigurationFilePaths(
            environment: environment,
            appServerConfigurationArguments: appServerConfigurationArguments
        )
        let cacheKeyComponents = codexResumeTrustProbeCacheKeyComponents(
            executablePath: executablePath,
            appServerConfigurationArguments: appServerConfigurationArguments,
            currentDirectory: currentDirectory,
            modelCatalogPath: modelCatalogPath,
            configurationPaths: configurationPaths,
            environment: environment
        )

        func readProjectDecisions(
            configurationArguments: [String]
        ) async -> Set<String>? {
            let result = await CLIProcessRunner.runJSONLinesProcess(
                executablePath: executablePath,
                arguments: configurationArguments + ["app-server", "--stdio"],
                stdinText: requests.initialize,
                followupStdinText: requests.afterInitialize,
                followupAfterResponseID: 1,
                responseID: 2,
                currentDirectoryPath: currentDirectory,
                timeout: 5
            )
            guard result.status == 0, !result.timedOut else {
                return nil
            }
            return policy.effectiveProjectDecisionPaths(
                appServerOutput: result.stdout,
                responseID: 2
            )
        }

        // config/read does not need a live model catalog. Loading Codex's own
        // version-compatible cache as a fixed catalog keeps an unrelated model
        // refresh or credential command from delaying every restored session.
        // A missing/invalid cache or managed requirement can reject this
        // session override, so retry the original effective configuration.
        return await CodexResumeTrustProbeCache(
            directory: codexResumeTrustProbeCacheDirectory(
                environment: environment
            ),
            fileManager: .default
        ).resolve(
            keyComponents: cacheKeyComponents
        ) {
            if let modelCatalogPath {
                let isolatedConfigurationArguments = appServerConfigurationArguments + [
                    "-c",
                    "model_catalog_json=\(modelCatalogPath)",
                ]
                if let decisions = await readProjectDecisions(
                    configurationArguments: isolatedConfigurationArguments
                ) {
                    return decisions
                }
            }
            return await readProjectDecisions(
                configurationArguments: appServerConfigurationArguments
            )
        }
    }

    private func codexResumeTrustProbeCacheKeyComponents(
        executablePath: String,
        appServerConfigurationArguments: [String],
        currentDirectory: String,
        modelCatalogPath: String?,
        configurationPaths: [String],
        environment: [String: String]
    ) -> [String] {
        [
            "v2",
            codexResumeTrustProbeFileIdentity(path: executablePath),
            currentDirectory,
            environment["CODEX_HOME"] ?? "",
            environment["HOME"] ?? "",
            appServerConfigurationArguments.joined(separator: "\u{0}"),
            modelCatalogPath.map(codexResumeTrustProbeFileIdentity(path:)) ?? "",
            configurationPaths
                .map(codexResumeTrustProbeFileIdentity(path:))
                .joined(separator: "\u{0}"),
        ]
    }

    private func codexResumeTrustProbeFileIdentity(path: String) -> String {
        let url = URL(fileURLWithPath: path, isDirectory: false)
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        )
        let modifiedAt = (attributes?[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let device = (attributes?[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes?[.systemFileNumber] as? NSNumber)?
            .uint64Value ?? 0
        return [
            url.standardizedFileURL.path,
            url.resolvingSymlinksInPath().path,
            String(device),
            String(inode),
            String(size),
            String(modifiedAt),
        ].joined(separator: "\u{0}")
    }

    private func codexResumeTrustProbeCacheDirectory(
        environment: [String: String]
    ) -> URL {
        let statePath = NSString(
            string: agentHookStatePath(
                sessionStoreSuffix: "codex",
                env: environment
            )
        ).expandingTildeInPath
        let directory = URL(
            fileURLWithPath: statePath,
            isDirectory: false
        )
        .deletingLastPathComponent()
        .appendingPathComponent(
            "codex-resume-trust-probes",
            isDirectory: true
        )
        return directory
    }

    private func codexModelsCachePath(
        environment: [String: String]
    ) -> String? {
        guard let codexHome = codexHomeDirectory(environment: environment) else {
            return nil
        }
        let path = codexHome
            .appendingPathComponent("models_cache.json", isDirectory: false)
            .standardizedFileURL
            .path
        return FileManager.default.isReadableFile(atPath: path) ? path : nil
    }

    /// Every local file that can change `config/read` for this invocation.
    /// Project-local files are intentionally excluded because Codex disables
    /// them until the project itself has already received a trust decision.
    private func codexConfigurationFilePaths(
        environment: [String: String],
        appServerConfigurationArguments: [String]
    ) -> [String] {
        var paths = [
            "/etc/codex/config.toml",
            "/etc/codex/managed_config.toml",
            "/etc/codex/requirements.toml",
        ]
        guard let codexHome = codexHomeDirectory(environment: environment) else {
            return paths
        }
        paths.append(
            codexHome.appendingPathComponent("config.toml", isDirectory: false)
                .standardizedFileURL.path
        )
        var selectedProfile: String?
        var index = 0
        while index < appServerConfigurationArguments.count {
            let argument = appServerConfigurationArguments[index]
            if argument == "--profile",
               index + 1 < appServerConfigurationArguments.count {
                selectedProfile = appServerConfigurationArguments[index + 1]
                index += 2
            } else if argument == "-c" {
                index += 2
            } else {
                index += 1
            }
        }
        if let profile = selectedProfile {
            paths.append(
                codexHome.appendingPathComponent(
                    "\(profile).config.toml",
                    isDirectory: false
                ).standardizedFileURL.path
            )
        }
        return paths
    }

    private func codexHomeDirectory(
        environment: [String: String]
    ) -> URL? {
        if let configuredHome = normalizedHookValue(environment["CODEX_HOME"]) {
            guard configuredHome.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: configuredHome, isDirectory: true)
                .standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL
    }

    private func codexConfigReadRequests(
        currentDirectory: String
    ) -> (initialize: String, afterInitialize: String)? {
        let messages: [[String: Any]] = [
            [
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": [
                        "name": "cmux",
                        "title": "cmux",
                        "version": "1",
                    ],
                ],
            ],
            [
                "method": "initialized",
            ],
            [
                "method": "config/read",
                "id": 2,
                "params": [
                    "includeLayers": false,
                    "cwd": currentDirectory,
                ],
            ],
        ]
        var lines: [String] = []
        for message in messages {
            guard let data = try? JSONSerialization.data(withJSONObject: message),
                  let line = String(data: data, encoding: .utf8) else {
                return nil
            }
            lines.append(line)
        }
        guard let initialize = lines.first else { return nil }
        return (
            initialize: initialize + "\n",
            afterInitialize: lines.dropFirst().joined(separator: "\n") + "\n"
        )
    }

    /// Mirrors Codex's trust lookup for linked worktrees: project decisions may
    /// be keyed by the main repository root rather than the checkout root. A
    /// failed probe is distinct from a confirmed non-repository so an
    /// invocation-only override cannot hide an authoritative root decision.
    private func codexRepositoryDecisionRoots(
        currentDirectory: String
    ) async -> (resolved: Bool, roots: [String]) {
        let result = await CommandRunner().run(
            directory: currentDirectory,
            executable: "/usr/bin/env",
            arguments: [
                "LC_ALL=C",
                "/usr/bin/git",
                "-C",
                currentDirectory,
                "rev-parse",
                "--path-format=absolute",
                "--show-toplevel",
                "--git-dir",
                "--git-common-dir",
            ],
            timeout: 1
        )
        if result.executionError == nil,
           result.exitStatus == 0,
           !result.timedOut {
            let paths = (result.stdout ?? "")
                .split(whereSeparator: \.isNewline)
                .compactMap { normalizedHookValue(String($0)) }
            guard paths.count == 3,
                  paths.allSatisfy({ $0.hasPrefix("/") }) else {
                return (false, [])
            }
            let checkoutURL = URL(
                fileURLWithPath: paths[0],
                isDirectory: true
            ).standardizedFileURL
            let gitURL = URL(
                fileURLWithPath: paths[1],
                isDirectory: true
            ).standardizedFileURL
            let commonURL = URL(
                fileURLWithPath: paths[2],
                isDirectory: true
            ).standardizedFileURL

            var roots = [checkoutURL.path]
            let worktreesURL = gitURL.deletingLastPathComponent()
            if worktreesURL.lastPathComponent == "worktrees",
               worktreesURL.deletingLastPathComponent().path
                == commonURL.path {
                roots.append(
                    commonURL
                        .deletingLastPathComponent()
                        .standardizedFileURL
                        .path
                )
            }
            return (true, Array(Set(roots)).sorted())
        }

        guard result.executionError == nil,
              !result.timedOut,
              result.exitStatus == 128,
              (result.stderr ?? "").contains("not a git repository"),
              !codexRepositoryEnvironmentIsConfigured(),
              !codexRepositoryMarkerExists(currentDirectory: currentDirectory) else {
            return (false, [])
        }
        return (true, [])
    }

    private func codexRepositoryEnvironmentIsConfigured() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return normalizedHookValue(environment["GIT_DIR"]) != nil
            || normalizedHookValue(environment["GIT_WORK_TREE"]) != nil
    }

    private func codexRepositoryMarkerExists(
        currentDirectory: String
    ) -> Bool {
        let logicalURL = URL(
            fileURLWithPath: currentDirectory,
            isDirectory: true
        ).standardizedFileURL
        let canonicalURL = logicalURL.resolvingSymlinksInPath()
        var startingURLs = [logicalURL]
        if canonicalURL.path != logicalURL.path {
            startingURLs.append(canonicalURL)
        }

        for startingURL in startingURLs {
            var directory = startingURL
            while true {
                if FileManager.default.fileExists(
                    atPath: directory
                        .appendingPathComponent(".git", isDirectory: false)
                        .path
                ) {
                    return true
                }
                let parent = directory.deletingLastPathComponent()
                guard parent.path != directory.path else {
                    break
                }
                directory = parent
            }
        }
        return false
    }

    /// The cmux-owned directory holding the generated codex hook scripts.
    /// `~/.cmux/hooks` (NOT the user's `~/.codex`), created on demand. Returns
    /// nil if it cannot be created, so the caller falls back to inline commands.
    static func codexHookScriptsDirectory() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    /// Writes (idempotently) a `#!/bin/sh` hook script for one event into `dir`
    /// and returns its absolute path, or nil on any failure. The body is the
    /// same env-driven fire-and-forget snippet used inline; as a real executable
    /// file it runs under any runtime, including ones that exec the hook command
    /// directly rather than through a shell. Content is identical across
    /// invocations, so the file is only rewritten when missing or changed.
    static func writeCodexHookScript(subcommand: String, body: String, in dir: URL) -> String? {
        let contents = "#!/bin/sh\n\(body)\n"
        guard let scriptName = CodexHookScriptName(
            contents: contents,
            subcommand: subcommand
        ) else {
            return nil
        }
        // Keep generated scripts immutable. Older cmux processes may still write
        // the legacy path while newer Codex sessions reference this content ID.
        let url = dir.appendingPathComponent(
            scriptName.filename,
            isDirectory: false
        )
        let fileManager = FileManager.default
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == contents {
            // Ensure it stays executable, then reuse.
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }
        do {
            try contents.data(using: .utf8)?.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        } catch {
            return nil
        }
    }

    static func codexFireAndForgetAgentHookShellCommand(_ command: String, for def: AgentHookDef) -> String {
        let routedArguments = command.hasPrefix("cmux ") ? String(command.dropFirst("cmux ".count)) : command
        let runner = "payload=\"$1\"; shift; \"$@\" <\"$payload\" >/dev/null 2>&1 & child=\"$!\"; ( sleep 30; kill \"$child\" 2>/dev/null || true ) & watchdog=\"$!\"; wait \"$child\" 2>/dev/null || true; kill \"$watchdog\" 2>/dev/null || true; rm -f \"$payload\""
        let noOp = stdinDrainingHookNoOpShellCommand
        return [
            "cmux_cli=\"${CMUX_BUNDLED_CLI_PATH:-}\"",
            "if [ -z \"$cmux_cli\" ] || [ ! -x \"$cmux_cli\" ]; then cmux_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi",
            "agent_pid=\"${CMUX_CODEX_PID:-${PPID:-}}\"",
            "if [ -n \"$CMUX_SURFACE_ID\" ] && [ \"$\(def.disableEnvVar)\" != \"1\" ] && [ -n \"$cmux_cli\" ]; then payload=\"$(mktemp \"${TMPDIR:-/tmp}/cmux-codex-hook.XXXXXX\" 2>/dev/null || mktemp -t cmux-codex-hook 2>/dev/null)\" || { \(noOp); exit 0; }; cat >\"$payload\" || true; if [ -n \"${CMUX_SOCKET_PATH:-}\" ]; then CMUX_CODEX_PID=\"$agent_pid\" nohup sh -c '\(runner)' cmux-codex-hook \"$payload\" \"$cmux_cli\" --socket \"$CMUX_SOCKET_PATH\" \(routedArguments) >/dev/null 2>&1 & else CMUX_CODEX_PID=\"$agent_pid\" nohup sh -c '\(runner)' cmux-codex-hook \"$payload\" \"$cmux_cli\" \(routedArguments) >/dev/null 2>&1 & fi; echo '{}'; else \(noOp); fi",
        ].joined(separator: "; ")
    }
}
