import CMUXAgentLaunch
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

    /// The cmux-owned directory holding the generated codex hook scripts.
    /// `~/.cmux/hooks` (NOT the user's `~/.codex`), created on demand. Returns
    /// nil if it cannot be created, so the caller falls back to inline commands.
    static func codexHookScriptsDirectory() -> URL? {
        let home = ProcessInfo.processInfo.environment["HOME"]
            .flatMap { raw -> URL? in
                let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
            }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = home
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            return dir
        } catch {
            return nil
        }
    }

    /// Installs the bundled process-light hook sender at the stable event path.
    /// A copied executable works for both shell-driven Codex and compatible
    /// runtimes that exec the configured command path directly. Returning nil
    /// preserves the portable shell implementation as the compatibility path.
    static func writeCodexHookClient(subcommand: String, in dir: URL) -> String? {
        guard codexWrapperInjectionEvents.contains(where: { $0.cmuxSubcommand == subcommand }),
              let source = codexHookClientSourceURL() else {
            return nil
        }
        let safeName = subcommand.replacingOccurrences(
            of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression
        )
        // This native-only namespace cannot be overwritten by an older cmux
        // that still generates shell wrappers at cmux-codex-hook-*.sh.
        let target = dir.appendingPathComponent("cmux-codex-native-hook-\(safeName)", isDirectory: false)
        let fileManager = FileManager.default
        if fileManager.contentsEqual(atPath: source.path, andPath: target.path) {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            return target.path
        }
        do {
            let executable = try Data(contentsOf: source, options: [.mappedIfSafe])
            try executable.write(to: target, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            return target.path
        } catch {
            return nil
        }
    }

    private static func codexHookClientSourceURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        if let override = environment["CMUX_CODEX_HOOK_CLIENT_PATH"] {
            let path = override.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
            return fileManager.isExecutableFile(atPath: url.path) ? url : nil
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
        let url = dir.appendingPathComponent("cmux-codex-portable-hook-\(safeName).sh", isDirectory: false)
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
            "export CMUX_CODEX_PID=\"$agent_pid\"",
            "delivery_id=\"${CMUX_AGENT_HOOK_DELIVERY_ID:-codex-${agent_pid:-unknown}-\(subcommand)-$$-${RANDOM:-0}-${RANDOM:-0}}\"",
            "if [ -n \"$CMUX_SURFACE_ID\" ] && [ \"$\(def.disableEnvVar)\" != \"1\" ] && [ -n \"$cmux_cli\" ]; then payload=\"$(mktemp \"${TMPDIR:-/tmp}/cmux-codex-portable.XXXXXX\" 2>/dev/null || mktemp -t cmux-codex-portable 2>/dev/null)\" || payload=''; if [ -n \"$payload\" ]; then /bin/cat >\"$payload\" || true; ( if [ -n \"${CMUX_SOCKET_PATH:-}\" ]; then CMUX_CODEX_PID=\"$agent_pid\" CMUX_AGENT_HOOK_DELIVERY_ID=\"$delivery_id\" CMUX_AGENT_HOOK_DELIVERY_PROCESS_GROUP=1 \"$cmux_cli\" --socket \"$CMUX_SOCKET_PATH\" \(fallbackArguments) <\"$payload\" >/dev/null 2>&1 & else CMUX_CODEX_PID=\"$agent_pid\" CMUX_AGENT_HOOK_DELIVERY_ID=\"$delivery_id\" CMUX_AGENT_HOOK_DELIVERY_PROCESS_GROUP=1 \"$cmux_cli\" \(fallbackArguments) <\"$payload\" >/dev/null 2>&1 & fi; child=$!; ( /bin/sleep 2; /bin/kill -TERM -- \"-$child\" 2>/dev/null || true; /bin/kill -TERM \"$child\" 2>/dev/null || true; /bin/sleep 0.05; /bin/kill -KILL -- \"-$child\" 2>/dev/null || true; /bin/kill -KILL \"$child\" 2>/dev/null || true ) & watchdog=$!; wait \"$child\" 2>/dev/null || true; /bin/kill \"$watchdog\" 2>/dev/null || true; wait \"$watchdog\" 2>/dev/null || true; /bin/rm -f \"$payload\" ) </dev/null >/dev/null 2>&1 & echo '{}'; else /bin/cat >/dev/null 2>&1 || true; echo '{}'; fi; else /bin/cat >/dev/null 2>&1 || true; echo '{}'; fi",
        ].joined(separator: "; ")
    }

    func enqueueCodexWrapperHook(commandArgs: [String], client: SocketClient) throws {
        guard let subcommand = commandArgs.first?.lowercased(),
              Set(Self.codexWrapperInjectionEvents.map { $0.cmuxSubcommand }).contains(subcommand) else {
            throw CLIError(message: String(
                localized: "cli.hooks.codex.enqueue.usage",
                defaultValue: "Usage: cmux hooks codex enqueue <session-start|prompt-submit|stop|pre-tool-use|post-tool-use|notification>"
            ))
        }
        let processEnvironment = ProcessInfo.processInfo.environment
        var environment = AgentHookTransportEnvironmentPolicy()
            .selectedEnvironment(from: processEnvironment)
        environment["CMUX_SOCKET_PATH"] = client.socketPath
        let payload = FileHandle.standardInput.readDataToEndOfFile()
        _ = try client.sendV2(
            method: "agent.hook.enqueue",
            params: [
                "delivery_id": processEnvironment["CMUX_AGENT_HOOK_DELIVERY_ID"]
                    ?? "codex-cli-\(getpid())-\(UUID().uuidString.lowercased())",
                "agent": "codex",
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
