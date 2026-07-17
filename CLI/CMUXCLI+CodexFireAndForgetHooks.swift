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
        for event in Self.codexWrapperInjectionEvents {
            let ff = Self.codexQueuedAgentHookShellCommand(
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
        let safeName = subcommand.replacingOccurrences(
            of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression
        )
        let url = dir.appendingPathComponent("cmux-codex-hook-\(safeName).sh", isDirectory: false)
        let contents = "#!/bin/sh\n\(body)\n"
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

    static func codexQueuedAgentHookShellCommand(_ command: String, for def: AgentHookDef) -> String {
        let subcommand = command.hasPrefix("cmux hooks codex ")
            ? String(command.dropFirst("cmux hooks codex ".count))
            : command
        let fallbackArguments = "hooks codex enqueue \(subcommand)"
        return [
            "cmux_cli=\"${CMUX_BUNDLED_CLI_PATH:-}\"",
            "if [ -z \"$cmux_cli\" ] || [ ! -x \"$cmux_cli\" ]; then cmux_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi",
            "agent_pid=\"${CMUX_CODEX_PID:-${PPID:-}}\"",
            "if [ -n \"$CMUX_SURFACE_ID\" ] && [ \"$\(def.disableEnvVar)\" != \"1\" ]; then IFS= read -r payload || payload='{}'; if [ -n \"${CMUX_SOCKET_PATH:-}\" ] && [ -n \"${CMUX_SOCKET_CAPABILITY:-}\" ] && [ -z \"${CODEX_HOME:-}\" ] && [ -x /usr/bin/nc ]; then request='{" +
                "\"id\":\"hook-'\"$$\"'\",\"method\":\"agent.hook.enqueue\",\"params\":{" +
                "\"agent\":\"codex\",\"subcommand\":\"\(subcommand)\",\"payload_json\":'\"$payload\"'," +
                "\"socket_path\":\"'\"$CMUX_SOCKET_PATH\"'\",\"environment\":{" +
                "\"CMUX_CODEX_PID\":\"'\"$agent_pid\"'\",\"CMUX_SURFACE_ID\":\"'\"$CMUX_SURFACE_ID\"'\"," +
                "\"CMUX_WORKSPACE_ID\":\"'\"${CMUX_WORKSPACE_ID:-}\"'\",\"CMUX_TAG\":\"'\"${CMUX_TAG:-}\"'\"," +
                "\"CMUX_AGENT_HOOK_STATE_DIR\":\"'\"${CMUX_AGENT_HOOK_STATE_DIR:-}\"'\"," +
                "\"CMUX_AGENT_LAUNCH_ARGV_B64\":\"'\"${CMUX_AGENT_LAUNCH_ARGV_B64:-}\"'\"," +
                "\"CMUX_AGENT_LAUNCH_KIND\":\"'\"${CMUX_AGENT_LAUNCH_KIND:-}\"'\"," +
                "\"CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS\":\"'\"${CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS:-}\"'\"," +
                "\"CMUX_AGENT_MANAGED_SUBAGENT\":\"'\"${CMUX_AGENT_MANAGED_SUBAGENT:-}\"'\"," +
                "\"CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS\":\"'\"${CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS:-}\"'\"}}}'; " +
                "attempt=0; response=''; while [ \"$attempt\" -lt 3 ]; do response=\"$(printf '_cmux_capability_v1 %s %s\\n' \"$CMUX_SOCKET_CAPABILITY\" \"$request\" | /usr/bin/nc -U -w 1 \"$CMUX_SOCKET_PATH\" 2>/dev/null || true)\"; case \"$response\" in *'\"queued\":true'*) break ;; esac; attempt=$((attempt + 1)); done; " +
                "case \"$response\" in *'\"queued\":true'*) echo '{}' ;; *) if [ -n \"$cmux_cli\" ]; then printf '%s' \"$payload\" | CMUX_CODEX_PID=\"$agent_pid\" \"$cmux_cli\" \(fallbackArguments) || echo '{}'; else echo '{}'; fi ;; esac; " +
                "elif [ -n \"$cmux_cli\" ]; then printf '%s' \"$payload\" | CMUX_CODEX_PID=\"$agent_pid\" \"$cmux_cli\" \(fallbackArguments) || echo '{}'; else echo '{}'; fi; else echo '{}'; fi",
        ].joined(separator: "; ")
    }

    func enqueueCodexLifecycleHook(commandArgs: [String], client: SocketClient) throws {
        guard let subcommand = commandArgs.first?.lowercased(),
              ["session-start", "prompt-submit", "stop"].contains(subcommand) else {
            throw CLIError(message: "Usage: cmux hooks codex enqueue <session-start|prompt-submit|stop>")
        }
        let processEnvironment = ProcessInfo.processInfo.environment
        let forwardedKeys = [
            "HOME", "PATH", "PWD", "TMPDIR", "CODEX_HOME",
            "CMUX_AGENT_HOOK_STATE_DIR", "CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS",
            "CMUX_AGENT_LAUNCH_ARGV_B64", "CMUX_AGENT_LAUNCH_CWD",
            "CMUX_AGENT_LAUNCH_EXECUTABLE", "CMUX_AGENT_LAUNCH_KIND",
            "CMUX_AGENT_MANAGED_SUBAGENT", "CMUX_BUNDLE_ID", "CMUX_CODEX_PID",
            "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS", "CMUX_SURFACE_ID", "CMUX_TAG",
            "CMUX_WORKSPACE_ID",
        ]
        var environment: [String: String] = [:]
        for key in forwardedKeys {
            if let value = processEnvironment[key] {
                environment[key] = value
            }
        }
        let payload = String(
            data: FileHandle.standardInput.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        _ = try client.sendV2(
            method: "agent.hook.enqueue",
            params: [
                "agent": "codex",
                "subcommand": subcommand,
                "payload": payload,
                "socket_path": client.socketPath,
                "environment": environment,
            ],
            responseTimeout: 1
        )
        print("{}")
    }
}
