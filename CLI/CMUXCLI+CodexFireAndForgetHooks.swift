import CMUXAgentLaunch
import CryptoKit
import Darwin
import Foundation

extension CMUXCLI {
    /// The per-invocation Codex hook events the wrapper injects, paired with the
    /// cmux subcommand they call and the codex hook timeout (ms). Lifecycle
    /// events are short; feed events (`PreToolUse`/`PermissionRequest`) are long
    /// because the user may take time to approve. This is the single source of
    /// truth for `cmux-codex-wrapper`'s injection, mirrored from the historic
    /// hand-rolled `cmux_codex_add_hook` calls in the wrapper.
    static let codexWrapperInjectionEvents: [(agentEvent: String, cmuxSubcommand: String, timeoutMs: Int)] = [
        ("SessionStart", "session-start", 10000),
        ("UserPromptSubmit", "prompt-submit", 10000),
        ("Stop", "stop", 10000),
        ("PreToolUse", "pre-tool-use", 120000),
        ("PostToolUse", "post-tool-use", 10000),
        ("PermissionRequest", "notification", 120000),
    ]

    static let codexFeedTelemetryEvents = [
        "PreToolUse", "PermissionRequest", "PostToolUse", "PreCompact",
        "PostCompact", "SubagentStart", "SubagentStop",
    ]

    struct ClaudeQueuedHookDefinition {
        let agentEvent: String
        let matcher: String
        let subcommand: String
    }

    /// Claude hooks whose effects do not contribute a synchronous decision.
    /// Each is admitted by the native helper and later delivered by the app's
    /// bounded queue. PermissionRequest and CronCreate deliberately stay out of
    /// this list because their stdout is part of Claude's decision protocol.
    static let claudeQueuedHookDefinitions: [ClaudeQueuedHookDefinition] = [
        .init(agentEvent: "SessionStart", matcher: "", subcommand: "session-start"),
        .init(agentEvent: "UserPromptSubmit", matcher: "", subcommand: "prompt-submit"),
        .init(agentEvent: "Stop", matcher: "", subcommand: "stop"),
        .init(agentEvent: "SessionEnd", matcher: "", subcommand: "session-end"),
        .init(agentEvent: "Notification", matcher: "", subcommand: "notification"),
        .init(agentEvent: "PreToolUse", matcher: "", subcommand: "pre-tool-use"),
        .init(agentEvent: "PostToolUse", matcher: "PushNotification", subcommand: "push-notification"),
        .init(agentEvent: "SubagentStop", matcher: "", subcommand: "feed:SubagentStop"),
    ]

    static func codexFeedDeliverySubcommand(agentEvent: String) -> String {
        "feed:\(agentEvent)"
    }

    static func codexHookCanUseQueuedAdmission(_ subcommand: String) -> Bool {
        codexWrapperInjectionEvents.contains(where: { $0.cmuxSubcommand == subcommand })
            || codexFeedTelemetryEvents.contains(where: {
                codexFeedDeliverySubcommand(agentEvent: $0) == subcommand
            })
    }

    static func claudeHookCanUseQueuedAdmission(_ subcommand: String) -> Bool {
        claudeQueuedHookDefinitions.contains(where: { $0.subcommand == subcommand })
    }

    /// Emit, NUL-separated to stdout, the exact codex arg list the wrapper must
    /// splice ahead of the user's args to enable + inject cmux's fire-and-forget
    /// hooks for one codex invocation. Returns the arg list:
    ///   --enable\0hooks\0--dangerously-bypass-hook-trust\0
    ///   -c\0hooks.SessionStart=[{hooks=[{type="command",command='''<ff>''',timeout=10000}]}]\0
    ///   -c\0hooks.UserPromptSubmit=...\0 ... (one `-c` pair per event)
    /// where `<ff>` is `codexQueuedAgentHookShellCommand(...)` so each hook
    /// returns after the app accepts the event into its bounded delivery queue.
    /// Requires no live socket: pure string construction from the agent def.
    func emitCodexWrapperInjectArgs() throws {
        guard let codexDef = Self.agentDef(named: "codex") else {
            throw CLIError(message: "Codex hook integration is unavailable.")
        }
        // Prefer the native hook client at a stable executable path. Some
        // codex-compatible runtimes exec `command` directly instead of through a
        // shell, so an inline snippet fails with "No such file or directory (os
        // error 2)". The native client removes the shell/base64/nc process tree.
        // A generated shell script remains the portable fallback when the native
        // client is unavailable (for example, a remote non-macOS installation).
        let hooksDir = Self.codexHookScriptsDirectory()
        var args: [String] = ["--enable", "hooks", "--dangerously-bypass-hook-trust"]
        for event in Self.codexWrapperInjectionEvents {
            let ff = Self.codexQueuedAgentHookShellCommand(
                "cmux hooks codex \(event.cmuxSubcommand)", for: codexDef
            )
            let command: String
            if let nativePath = hooksDir.flatMap({
                Self.writeCodexHookClient(subcommand: event.cmuxSubcommand, in: $0)
            }) {
                command = nativePath
            } else if let scriptPath = hooksDir.flatMap({
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
        // NUL-TERMINATE each arg (trailing NUL after the last too) so a bash
        // `while IFS= read -r -d '' arg` loop captures every element including
        // the final one — a separator-only stream drops the unterminated last
        // arg at EOF.
        var out = Data()
        for arg in args {
            out.append(Data(arg.utf8))
            out.append(0)
        }
        FileHandle.standardOutput.write(out)
    }

    /// Emits the complete cmux-owned Claude settings object. This method has no
    /// socket dependency, so the wrapper can generate settings before Claude
    /// starts while the app is busy with any number of other hook deliveries.
    ///
    /// Non-decision hooks use immutable content-addressed native senders.
    /// PermissionRequest and CronCreate remain direct because Claude consumes
    /// their stdout synchronously. If a sender cannot be installed, throwing
    /// makes the wrapper use its exact legacy settings object instead of mixing
    /// native and legacy behavior in one invocation.
    func emitClaudeWrapperInjectSettings() throws {
        guard let hooksDirectory = Self.codexHookScriptsDirectory() else {
            throw CLIError(message: String(
                localized: "cli.hooks.claude.injectSettings.error.directoryUnavailable",
                defaultValue: "Claude native hook directory is unavailable."
            ))
        }

        var commandsBySubcommand: [String: String] = [:]
        commandsBySubcommand.reserveCapacity(Self.claudeQueuedHookDefinitions.count)
        for definition in Self.claudeQueuedHookDefinitions {
            guard let command = Self.writeAgentHookClient(
                agent: "claude",
                subcommand: definition.subcommand,
                in: hooksDirectory
            ) else {
                throw CLIError(message: String(
                    localized: "cli.hooks.claude.injectSettings.error.clientUnavailable",
                    defaultValue: "Claude native hook client is unavailable."
                ))
            }
            commandsBySubcommand[definition.subcommand] = command
        }

        func commandHook(_ command: String, timeout: Int) -> [String: Any] {
            ["type": "command", "command": command, "timeout": timeout]
        }
        func group(matcher: String, hook: [String: Any]) -> [String: Any] {
            ["matcher": matcher, "hooks": [hook]]
        }
        func nativeGroup(_ definition: ClaudeQueuedHookDefinition) throws -> [String: Any] {
            guard let command = commandsBySubcommand[definition.subcommand] else {
                throw CLIError(message: String(
                    localized: "cli.hooks.claude.injectSettings.error.commandUnavailable",
                    defaultValue: "Claude native hook command is unavailable."
                ))
            }
            return group(matcher: definition.matcher, hook: commandHook(command, timeout: 1))
        }

        var hooks: [String: [[String: Any]]] = [:]
        for definition in Self.claudeQueuedHookDefinitions {
            hooks[definition.agentEvent, default: []].append(try nativeGroup(definition))
        }

        let hookCLI = #""${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}""#
        let cronCreate = commandHook(
            "\(hookCLI) hooks claude cron-create-guard",
            timeout: 5
        )
        hooks["PreToolUse", default: []].insert(
            group(matcher: "CronCreate", hook: cronCreate),
            at: 0
        )
        let permissionRequest = commandHook(
            "\(hookCLI) hooks feed --source claude",
            timeout: 125
        )
        hooks["PermissionRequest"] = [
            group(matcher: "", hook: permissionRequest),
        ]

        let settings: [String: Any] = [
            "preferredNotifChannel": "notifications_disabled",
            "hooks": hooks,
        ]
        guard JSONSerialization.isValidJSONObject(settings) else {
            throw CLIError(message: String(
                localized: "cli.hooks.claude.injectSettings.error.invalid",
                defaultValue: "Claude native hook settings are invalid."
            ))
        }
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        FileHandle.standardOutput.write(data)
    }

    /// The cmux-owned directory holding generated Codex hook executables.
    ///
    /// Hook configuration has one command string shared by two runtime
    /// contracts: Codex runs it through a shell, while some compatible runtimes
    /// pass it directly to `exec`. A bare path containing shell syntax (including
    /// whitespace) cannot satisfy both contracts. Keep the historical
    /// `~/.cmux/hooks` location when its path is a safe shell word; otherwise use
    /// a private per-uid directory below `/Users/Shared`, whose path is stable,
    /// persistent across reboots, and contains no shell syntax.
    ///
    /// Returns nil if neither private directory can be established, so callers
    /// retain the existing inline-shell compatibility fallback.
    static func codexHookScriptsDirectory() -> URL? {
        let home = ProcessInfo.processInfo.environment["HOME"]
            .flatMap { raw -> URL? in
                let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
            }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let homeDirectory = home
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)

        if codexHookPathIsSafeBareShellWord(homeDirectory.path),
           let directory = createPrivateCodexHookDirectory(homeDirectory) {
            return directory
        }

        let sharedDirectory = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent(".cmux-hooks-\(geteuid())", isDirectory: true)
        return createPrivateCodexHookDirectory(sharedDirectory)
    }

    private static func codexHookPathIsSafeBareShellWord(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let shellSyntax = CharacterSet(charactersIn: " \t\r\n\\\"'\u{60}$&;|<>()*?[]{}!")
        return path.unicodeScalars.allSatisfy { !shellSyntax.contains($0) }
    }

    private static func createPrivateCodexHookDirectory(_ directory: URL) -> URL? {
        let fileManager = FileManager.default
        let path = directory.standardizedFileURL.path

        var status = stat()
        if lstat(path, &status) != 0 {
            guard errno == ENOENT else { return nil }
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                return nil
            }
            guard lstat(path, &status) == 0 else { return nil }
        }

        guard (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid() else {
            return nil
        }

        if status.st_mode & 0o077 != 0 {
            guard chmod(path, 0o700) == 0,
                  lstat(path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFDIR,
                  status.st_uid == geteuid(),
                  status.st_mode & 0o077 == 0 else {
                return nil
            }
        }
        return directory.standardizedFileURL
    }

    /// Installs the bundled process-light hook sender at the stable event path.
    /// A copied executable works for both shell-driven Codex and compatible
    /// runtimes that exec the configured command path directly. Returning nil
    /// preserves the portable shell implementation as the compatibility path.
    static func writeCodexHookClient(subcommand: String, in dir: URL) -> String? {
        writeAgentHookClient(agent: "codex", subcommand: subcommand, in: dir)
    }

    /// Installs the shared native sender under an agent-specific immutable path.
    /// The executable basename is the sender's capability: the C client accepts
    /// only the exact agent/subcommand combinations generated here.
    static func writeAgentHookClient(
        agent: String,
        subcommand: String,
        in dir: URL
    ) -> String? {
        let supportsSubcommand: Bool
        switch agent {
        case "codex":
            supportsSubcommand = codexHookCanUseQueuedAdmission(subcommand)
        case "claude":
            supportsSubcommand = claudeHookCanUseQueuedAdmission(subcommand)
        default:
            supportsSubcommand = false
        }
        guard supportsSubcommand,
              let source = agentHookClientSourceURL(agent: agent) else {
            return nil
        }
        let safeName = subcommand.replacingOccurrences(
            of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression
        )
        let fileManager = FileManager.default
        guard let executable = try? Data(contentsOf: source, options: [.mappedIfSafe]) else {
            return nil
        }
        let digest = codexHookContentDigest(executable)
        // Immutable, content-addressed paths let tagged, nightly, and stable
        // builds coexist without changing a helper already referenced by a
        // running agent process.
        let target = dir.appendingPathComponent(
            "cmux-\(agent)-native-hook-\(safeName)-\(digest)",
            isDirectory: false
        )
        if fileManager.contentsEqual(atPath: source.path, andPath: target.path) {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            return target.path
        }
        do {
            try executable.write(to: target, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            return target.path
        } catch {
            return nil
        }
    }

    private static func agentHookClientSourceURL(agent: String) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        let overrideKeys = [
            "CMUX_AGENT_HOOK_CLIENT_PATH",
            agent == "claude" ? "CMUX_CLAUDE_HOOK_CLIENT_PATH" : "CMUX_CODEX_HOOK_CLIENT_PATH",
        ]
        for overrideKey in overrideKeys {
            guard let override = environment[overrideKey] else { continue }
            let path = override.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            let url = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        var candidates: [URL] = []
        if let executable = CommandLine.arguments.first, !executable.isEmpty {
            candidates.append(
                URL(fileURLWithPath: executable, isDirectory: false)
                    .resolvingSymlinksInPath()
                    .deletingLastPathComponent()
                    .appendingPathComponent("cmux-codex-hook-client", isDirectory: false)
            )
        }
        if let bundledCLI = environment["CMUX_BUNDLED_CLI_PATH"], !bundledCLI.isEmpty {
            candidates.append(
                URL(fileURLWithPath: bundledCLI, isDirectory: false)
                    .resolvingSymlinksInPath()
                    .deletingLastPathComponent()
                    .appendingPathComponent("cmux-codex-hook-client", isDirectory: false)
            )
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(
                resources
                    .appendingPathComponent("bin", isDirectory: true)
                    .appendingPathComponent("cmux-codex-hook-client", isDirectory: false)
            )
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// Writes (idempotently) a `#!/bin/sh` hook script for one event into `dir`
    /// and returns its absolute path, or nil on any failure. The body is the
    /// same env-driven fire-and-forget snippet used inline; as a real executable
    /// file it runs under any runtime, including ones that exec the hook command
    /// directly rather than through a shell. Content is identical across
    /// invocations, so the file is only rewritten when missing or changed.
    static func writeCodexHookScript(subcommand: String, body: String, in dir: URL) -> String? {
        let safeName = subcommand.replacingOccurrences(
            of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression
        )
        let contents = "#!/bin/sh\n\(body)\n"
        guard let contentsData = contents.data(using: .utf8) else { return nil }
        let digest = codexHookContentDigest(contentsData)
        let url = dir.appendingPathComponent(
            "cmux-codex-portable-hook-\(safeName)-\(digest).sh",
            isDirectory: false
        )
        let fileManager = FileManager.default
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == contents {
            // Ensure it stays executable, then reuse.
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }
        do {
            try contentsData.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        } catch {
            return nil
        }
    }

    private static func codexHookContentDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func codexQueuedAgentHookShellCommand(_ command: String, for def: AgentHookDef) -> String {
        let subcommand = command.hasPrefix("cmux hooks codex ")
            ? String(command.dropFirst("cmux hooks codex ".count))
            : command
        let fallbackArguments = "hooks codex enqueue \(subcommand)"
        return [
            "cmux_cli=\"${CMUX_BUNDLED_CLI_PATH:-}\"",
            "if [ -z \"$cmux_cli\" ] || [ ! -x \"$cmux_cli\" ]; then cmux_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi",
            "agent_pid=\"${CMUX_CODEX_PID:-${PPID:-}}\"",
            "export CMUX_CODEX_PID=\"$agent_pid\"",
            "delivery_id=\"${CMUX_AGENT_HOOK_DELIVERY_ID:-codex-${agent_pid:-unknown}-\(subcommand)-$$-${RANDOM:-0}-${RANDOM:-0}}\"",
            "if [ -n \"$CMUX_SURFACE_ID\" ] && [ \"$\(def.disableEnvVar)\" != \"1\" ] && [ -n \"$cmux_cli\" ]; then payload=\"$(mktemp \"${TMPDIR:-/tmp}/cmux-codex-portable.XXXXXX\" 2>/dev/null || mktemp -t cmux-codex-portable 2>/dev/null)\" || payload=''; if [ -n \"$payload\" ]; then /bin/cat >\"$payload\" || true; ( if [ -n \"${CMUX_SOCKET_PATH:-}\" ]; then CMUX_CODEX_PID=\"$agent_pid\" CMUX_AGENT_HOOK_DELIVERY_ID=\"$delivery_id\" CMUX_AGENT_HOOK_DELIVERY_PROCESS_GROUP=1 \"$cmux_cli\" --socket \"$CMUX_SOCKET_PATH\" \(fallbackArguments) <\"$payload\" >/dev/null 2>&1 & else CMUX_CODEX_PID=\"$agent_pid\" CMUX_AGENT_HOOK_DELIVERY_ID=\"$delivery_id\" CMUX_AGENT_HOOK_DELIVERY_PROCESS_GROUP=1 \"$cmux_cli\" \(fallbackArguments) <\"$payload\" >/dev/null 2>&1 & fi; child=$!; attempts=0; while /bin/kill -0 \"$child\" 2>/dev/null && [ \"$attempts\" -lt 40 ]; do /bin/sleep 0.05; attempts=$((attempts + 1)); done; if /bin/kill -0 \"$child\" 2>/dev/null; then /bin/kill -TERM -- \"-$child\" 2>/dev/null || true; /bin/kill -TERM \"$child\" 2>/dev/null || true; /bin/sleep 0.05; /bin/kill -KILL -- \"-$child\" 2>/dev/null || true; /bin/kill -KILL \"$child\" 2>/dev/null || true; fi; wait \"$child\" 2>/dev/null || true; /bin/rm -f \"$payload\" ) </dev/null >/dev/null 2>&1 & echo '{}'; else /bin/cat >/dev/null 2>&1 || true; echo '{}'; fi; else /bin/cat >/dev/null 2>&1 || true; echo '{}'; fi",
        ].joined(separator: "; ")
    }

    func enqueueCodexWrapperHook(commandArgs: [String], client: SocketClient) throws {
        try enqueueWrapperHook(
            agent: "codex",
            commandArgs: commandArgs,
            client: client,
            supportsSubcommand: Self.codexHookCanUseQueuedAdmission,
            usage: String(
                localized: "cli.hooks.codex.enqueue.usage",
                defaultValue: "Usage: cmux hooks codex enqueue <session-start|prompt-submit|stop|pre-tool-use|post-tool-use|notification>"
            )
        )
    }

    func enqueueClaudeWrapperHook(commandArgs: [String], client: SocketClient) throws {
        try enqueueWrapperHook(
            agent: "claude",
            commandArgs: commandArgs,
            client: client,
            supportsSubcommand: Self.claudeHookCanUseQueuedAdmission,
            usage: String(
                localized: "cli.hooks.claude.enqueue.usage",
                defaultValue: "Usage: cmux hooks claude enqueue <session-start|prompt-submit|stop|session-end|notification|pre-tool-use|push-notification|feed:SubagentStop>"
            )
        )
    }

    private func enqueueWrapperHook(
        agent: String,
        commandArgs: [String],
        client: SocketClient,
        supportsSubcommand: (String) -> Bool,
        usage: String
    ) throws {
        guard let requestedSubcommand = commandArgs.first else {
            throw CLIError(message: usage)
        }
        let subcommand = requestedSubcommand.hasPrefix("feed:")
            ? requestedSubcommand
            : requestedSubcommand.lowercased()
        guard supportsSubcommand(subcommand) else {
            throw CLIError(message: usage)
        }
        let processEnvironment = ProcessInfo.processInfo.environment
        var environment = AgentHookTransportEnvironmentPolicy()
            .selectedEnvironment(from: processEnvironment, hookAgentKind: agent)
        environment["CMUX_SOCKET_PATH"] = client.socketPath
        let payload = FileHandle.standardInput.readDataToEndOfFile()
        _ = try client.sendV2(
            method: "agent.hook.enqueue",
            params: [
                "delivery_id": processEnvironment["CMUX_AGENT_HOOK_DELIVERY_ID"]
                    ?? "\(agent)-cli-\(getpid())-\(UUID().uuidString.lowercased())",
                "agent": agent,
                "subcommand": subcommand,
                "payload_b64": payload.base64EncodedString(),
                "socket_path": client.socketPath,
                "environment": environment,
            ],
            responseTimeout: 1
        )
        print("{}")
    }
}
