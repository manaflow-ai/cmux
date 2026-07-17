import Foundation

enum CodexHookWriterOwnership {
    case persistent
    case wrapperInjected
}

enum CodexHookDispatchTarget {
    case wrapperEnvironment
    case unavailable
}

extension CMUXCLI {
    static let codexWrapperHookOwnerEnvironmentKey = "CMUX_CODEX_WRAPPER_HOOK_OWNER"

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
        for event in Self.codexWrapperInjectionEvents {
            let ff = Self.codexFireAndForgetAgentHookShellCommand(
                "cmux hooks codex \(event.cmuxSubcommand)",
                for: codexDef,
                ownership: .wrapperInjected,
                target: .wrapperEnvironment
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

    /// Writes an immutable, content-addressed `#!/bin/sh` hook script for one
    /// event and returns its absolute path, or nil on failure. Stable event-only
    /// filenames let an older Nightly overwrite a newer tagged build's ownership
    /// gate while both are running. Including the content hash gives every cmux
    /// version its own executable and keeps already-launched Codex processes on
    /// the exact script they were configured to call.
    static func writeCodexHookScript(subcommand: String, body: String, in dir: URL) -> String? {
        let safeName = subcommand.replacingOccurrences(
            of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression
        )
        let contents = "#!/bin/sh\n\(body)\n"
        let contentHash = codexHookStableContentHash(contents)
        let url = dir.appendingPathComponent(
            "cmux-codex-hook-\(safeName)-\(contentHash).sh",
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

    private static func codexHookStableContentHash(_ contents: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in contents.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    static func codexFireAndForgetAgentHookShellCommand(
        _ command: String,
        for def: AgentHookDef,
        ownership: CodexHookWriterOwnership,
        target: CodexHookDispatchTarget
    ) -> String {
        let routedArguments = command.hasPrefix("cmux ") ? String(command.dropFirst("cmux ".count)) : command
        let runner = "payload=\"$1\"; shift; \"$@\" <\"$payload\" >/dev/null 2>&1 & child=\"$!\"; ( sleep 30; kill \"$child\" 2>/dev/null || true ) & watchdog=\"$!\"; wait \"$child\" 2>/dev/null || true; kill \"$watchdog\" 2>/dev/null || true; rm -f \"$payload\""
        let targetSetup: String
        let socketSetup: String
        switch target {
        case .wrapperEnvironment:
            // Every wrapper exports its exact bundled CLI and socket before
            // starting Codex. Keeping those values in the native process
            // environment makes the persistent hook command identical across
            // concurrent cmux instances, so shared hooks.json can never route
            // one Codex launch through another instance's pinned socket.
            // Fail closed if Codex strips the environment instead of selecting
            // an arbitrary cmux from PATH.
            targetSetup = "cmux_cli=\"${CMUX_CODEX_HOOK_CMUX_BIN:-${CMUX_BUNDLED_CLI_PATH:-}}\""
            socketSetup = "cmux_socket=\"${CMUX_SOCKET_PATH:-}\""
        case .unavailable:
            // State-mutating persistent hooks must not fall back to an arbitrary
            // PATH cmux. An older CLI can decode the shared store and erase fields
            // introduced by a newer schema.
            targetSetup = "cmux_cli=\"\""
            socketSetup = "cmux_socket=\"\""
        }
        let ownershipGate: String
        let agentPIDSetup: String
        switch ownership {
        case .persistent:
            ownershipGate = "[ \"$\(def.disableEnvVar)\" != \"1\" ]"
            // The wrapper exports the native Codex PID. Prefer it because some
            // runtimes insert a short-lived hook relay as this shell's PPID.
            agentPIDSetup = "agent_pid=\"${CMUX_CODEX_PID:-${PPID:-}}\""
        case .wrapperInjected:
            ownershipGate = "[ \"${\(Self.codexWrapperHookOwnerEnvironmentKey):-}\" = \"1\" ]"
            agentPIDSetup = "agent_pid=\"${CMUX_CODEX_PID:-${PPID:-}}\""
        }
        return [
            targetSetup,
            agentPIDSetup,
            socketSetup,
            "if [ -n \"$CMUX_SURFACE_ID\" ] && \(ownershipGate) && [ -n \"$cmux_cli\" ] && [ -x \"$cmux_cli\" ]; then payload=\"$(mktemp \"${TMPDIR:-/tmp}/cmux-codex-hook.XXXXXX\" 2>/dev/null || mktemp -t cmux-codex-hook 2>/dev/null)\" || { echo '{}'; exit 0; }; cat >\"$payload\" || true; if [ -n \"$cmux_socket\" ]; then CMUX_CODEX_PID=\"$agent_pid\" nohup sh -c '\(runner)' cmux-codex-hook \"$payload\" \"$cmux_cli\" --socket \"$cmux_socket\" \(routedArguments) >/dev/null 2>&1 & else CMUX_CODEX_PID=\"$agent_pid\" nohup sh -c '\(runner)' cmux-codex-hook \"$payload\" \"$cmux_cli\" \(routedArguments) >/dev/null 2>&1 & fi; echo '{}'; else echo '{}'; fi",
        ].joined(separator: "; ")
    }

    /// Content-addressed hook filenames change when the dispatcher generation
    /// changes. Reinstall must replace older cmux generations while preserving
    /// user hooks outside cmux's private hook directory.
    static func isCmuxManagedCodexHookScript(_ command: String) -> Bool {
        var path = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.count >= 2,
           let first = path.first,
           let last = path.last,
           first == last,
           (first == "\"" || first == "'") {
            path.removeFirst()
            path.removeLast()
        }
        guard path.hasPrefix("/") else { return false }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parent = url.deletingLastPathComponent().path
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        let filename = url.lastPathComponent.lowercased()
        return parent.hasSuffix("/.cmux/hooks")
            && filename.hasPrefix("cmux-codex-hook-")
            && filename.hasSuffix(".sh")
    }

    static func isLegacyCodexBundledDispatcher(_ command: String) -> Bool {
        guard command.contains("CMUX_BUNDLED_CLI_PATH"),
              command.contains("cmux_cli=") else {
            return false
        }
        return command.contains("hooks codex session-start")
            || command.contains("hooks codex prompt-submit")
            || command.contains("hooks codex stop")
            || command.contains("hooks feed --source codex")
    }
}
