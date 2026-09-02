import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    private static let codexSettledStopMaximumRetries = 3

    /// Schedules the normal Codex Stop path after the final child exits.
    ///
    /// Native child hooks must acknowledge the lifecycle write quickly, so the
    /// larger notification/store projection runs in a detached CLI process.
    /// The child-stop marker lets that process skip legacy prompt-depth
    /// inference; the ledger itself remains the single settlement authority.
    func spawnDetachedCodexSettledStop(
        payload: String,
        environment: [String: String],
        telemetry: CLISocketSentryTelemetry,
        turnID: String? = nil
    ) {
        let retryCount = max(0, Int(environment["CMUX_CODEX_SETTLED_STOP_RETRY_COUNT"] ?? "0") ?? 0)
        guard retryCount < Self.codexSettledStopMaximumRetries else {
            telemetry.breadcrumb("codex-hook.settled-stop.retry-limit-reached")
            return
        }
        let retryDelay = [0.0, 0.5, 1.0][min(retryCount, 2)]
        let selfPath: String = {
            if let first = ProcessInfo.processInfo.arguments.first,
               first.hasPrefix("/"),
               FileManager.default.isExecutableFile(atPath: first) {
                return first
            }
            if let bundled = normalizedHookValue(environment["CMUX_BUNDLED_CLI_PATH"]),
               FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
            return "cmux"
        }()
        let payloadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-codex-settled-stop-\(UUID().uuidString).json"
            )
        let payloadData = Data(payload.utf8)
        guard FileManager.default.createFile(
            atPath: payloadURL.path,
            contents: payloadData,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else {
            telemetry.breadcrumb("codex-hook.settled-stop.payload-write-failed")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "nohup /bin/sh -c 'sleep \"$2\"; \"$0\" hooks codex stop < \"$1\" >/dev/null 2>&1; rm -f \"$1\"' \"$0\" \"$1\" \"$2\" >/dev/null 2>&1 &",
            selfPath,
            payloadURL.path,
            String(retryDelay),
        ]
        var childEnvironment = environment
        childEnvironment["CMUX_CODEX_SETTLED_CHILD_STOP"] = "1"
        childEnvironment["CMUX_CODEX_SETTLED_STOP_RETRY_COUNT"] = String(retryCount + 1)
        if let turnID = turnID?.trimmingCharacters(in: .whitespacesAndNewlines), !turnID.isEmpty {
            childEnvironment["CMUX_CODEX_SETTLED_STOP_TURN_ID"] = turnID
        } else {
            childEnvironment.removeValue(forKey: "CMUX_CODEX_SETTLED_STOP_TURN_ID")
        }
        process.environment = childEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: payloadURL)
            telemetry.breadcrumb("codex-hook.settled-stop.spawn-failed")
        }
    }

    /// Emit, NUL-separated to stdout, the exact codex arg list the wrapper must
    /// splice ahead of the user's args to enable cmux hooks for one Codex
    /// invocation without rewriting the user's Codex configuration. Returns
    /// activation flags followed by one `-c` pair for every event that is not
    /// already supplied by a cmux-owned persistent hook:
    ///   --enable\0hooks\0--dangerously-bypass-hook-trust\0
    ///   -c\0hooks.SessionStart=[{hooks=[{type="command",command='''<hook>''',timeout=10000}]}]\0
    ///   -c\0hooks.UserPromptSubmit=...\0 ... (one `-c` pair per event)
    /// Turn/status hooks use `codexFireAndForgetAgentHookShellCommand(...)`;
    /// native child lifecycle hooks synchronously commit their ledger event and
    /// then return. All larger socket delivery remains non-blocking.
    /// Persistent hooks are inventoried read-only so the wrapper does not add a
    /// duplicate cmux producer. Codex combines hook sources, so user-owned hooks
    /// continue to run alongside these process-local entries. Only explicit
    /// `cmux hooks codex install` or `uninstall` commands mutate `CODEX_HOME`.
    /// No live socket is required.
    func emitCodexWrapperInjectArgs() throws {
        guard let codexDef = Self.agentDef(named: "codex") else {
            throw CLIError(message: "Codex hook integration is unavailable.")
        }
        let persistentEvents = codexPersistentHookEventNamesForWrapper()
        let eventsToInject = CodexHookInjectionSchema.current.events.filter {
            !persistentEvents.contains($0.agentEvent)
        }
        // A complete persistent channel is already the user's selected Codex
        // configuration. Do not even pass an activation override in that case;
        // this preserves an intentional `features.hooks = false` choice. A
        // partial or legacy channel still gets only its missing events below.
        guard !eventsToInject.isEmpty else { return }
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
        let hooksDir = eventsToInject.isEmpty ? nil : Self.codexHookScriptsDirectory()
        var args: [String] = ["--enable", "hooks", "--dangerously-bypass-hook-trust"]
        for event in eventsToInject {
            let hookBody = Self.codexWrapperHookBody(event: event, for: codexDef)
            let command: String
            if let scriptPath = hooksDir.flatMap({
                Self.writeCodexHookScript(subcommand: event.cmuxSubcommand, body: hookBody, in: $0)
            }), !scriptPath.contains("'''") {
                command = scriptPath
            } else {
                command = hookBody
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
        let dir = codexHookScriptsURL()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    /// The hook-script directory path without creating it.
    static func codexHookScriptsURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
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

    /// Names that the current wrapper schema may reference from a live session.
    static func currentCodexWrapperHookScriptFilenames(for def: AgentHookDef) -> Set<String> {
        Set(CodexHookInjectionSchema.current.events.compactMap { event in
            let body = codexWrapperHookBody(event: event, for: def)
            return CodexHookScriptName(
                contents: "#!/bin/sh\n\(body)\n",
                subcommand: event.cmuxSubcommand
            )?.filename
        })
    }

    private static func codexWrapperHookBody(
        event: CodexHookInjectionEvent,
        for def: AgentHookDef
    ) -> String {
        let command = "cmux hooks codex \(event.cmuxSubcommand)"
        if event.isSynchronous {
            return codexSynchronousAgentHookShellCommand(command, for: def)
        }
        return codexFireAndForgetAgentHookShellCommand(command, for: def)
    }

    /// Cmux-generated script names referenced by the active persistent config.
    static func installedCodexHookScriptFilenames(for def: AgentHookDef) -> Set<String> {
        let fileURL = URL(fileURLWithPath: def.resolvedConfigDir(), isDirectory: true)
            .appendingPathComponent(def.configFile, isDirectory: false)
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            return []
        }
        let hooksDirectory = codexHookScriptsURL().standardizedFileURL

        var filenames = Set<String>()
        for value in hooks.values {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else { continue }
                for handler in handlers {
                    guard let command = handler["command"] as? String else { continue }
                    let url = URL(fileURLWithPath: command, isDirectory: false)
                    guard url.deletingLastPathComponent().standardizedFileURL == hooksDirectory,
                          CodexHookScriptName(filename: url.lastPathComponent) != nil else {
                        continue
                    }
                    filenames.insert(url.lastPathComponent)
                }
            }
        }
        return filenames
    }

    /// Removes obsolete regular files only when their names prove cmux ownership.
    /// This runs only during an explicit hook install, never on wrapper launch
    /// or automatic reconciliation. Since an older immutable script may still
    /// be referenced by a long-lived Codex process, fail closed whenever any
    /// Codex process is running; the process probe is intentionally outside the
    /// launch path.
    static func garbageCollectCodexHookScripts(retaining filenames: Set<String>) {
        guard !hasRunningCodexProcess(),
              let directory = codexHookScriptsDirectory(),
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return
        }

        let newestRemovableDate = Date().addingTimeInterval(-24 * 60 * 60)
        let removableCandidates = contents.compactMap { url -> (url: URL, date: Date)? in
            guard !filenames.contains(url.lastPathComponent) else { return nil }
            let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
            ])
            guard CodexHookScriptName(filename: url.lastPathComponent) != nil,
                  values?.isRegularFile == true,
                  let modificationDate = values?.contentModificationDate,
                  modificationDate < newestRemovableDate else {
                return nil
            }
            return (url, modificationDate)
        }
        // Keep cleanup bounded if a damaged or very old installation has
        // accumulated an unexpectedly large number of generated files, while
        // deleting the oldest batch so later explicit installs make progress.
        let boundedCandidates = removableCandidates
            .sorted { lhs, rhs in
                if lhs.date != rhs.date { return lhs.date < rhs.date }
                return lhs.url.lastPathComponent < rhs.url.lastPathComponent
            }
            .prefix(256)
        for url in boundedCandidates {
            try? FileManager.default.removeItem(at: url.url)
        }
    }

    /// A running Codex process may have loaded an immutable hook path that is
    /// absent from the current config. Cleanup is explicit-install-only, so a
    /// synchronous fail-closed probe protects that process without adding
    /// launch latency or a background polling task.
    private static func hasRunningCodexProcess() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "codex"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return true
        }
    }

    static func codexFireAndForgetAgentHookShellCommand(_ command: String, for def: AgentHookDef) -> String {
        let routedArguments = command.hasPrefix("cmux ") ? String(command.dropFirst("cmux ".count)) : command
        // Keep timer ownership in one process and stop it through a file
        // handshake. A signal-based supervisor can receive TERM before its
        // trap/timer assignment is installed, orphaning the timer for a fast
        // child; the explicit parent-owned timer is always waited/reaped.
        let runner = "payload=\"$1\"; shift; timer_stop=\"$payload.timer-stop\"; timer_done=\"$payload.timer-done\"; kill_timer_tree() { timer_root=\"$1\"; for timer_child in $(/usr/bin/pgrep -P \"$timer_root\" 2>/dev/null || true); do kill_timer_tree \"$timer_child\"; done; kill \"$timer_root\" 2>/dev/null || true; }; rm -f \"$timer_stop\" \"$timer_done\"; ( sleep 30 & timer=\"$!\"; while [ ! -e \"$timer_stop\" ]; do timer_state=$(/bin/ps -o state= -p \"$timer\" 2>/dev/null | /usr/bin/tr -d \"[:space:]\"); case \"$timer_state\" in \"\"|Z*) wait \"$timer\" 2>/dev/null || true; printf done >\"$timer_done\"; exit 0;; esac; /bin/sleep 0.05; done; kill_timer_tree \"$timer\"; wait \"$timer\" 2>/dev/null || true; exit 0 ) & timer_supervisor=\"$!\"; \"$@\" <\"$payload\" >/dev/null 2>&1 & child=\"$!\"; ( while [ ! -s \"$timer_done\" ] && [ ! -e \"$timer_stop\" ]; do /bin/sleep 0.05; done; if [ -s \"$timer_done\" ]; then kill \"$child\" 2>/dev/null || true; fi ) & watchdog=\"$!\"; wait \"$child\" 2>/dev/null || true; : >\"$timer_stop\"; kill \"$watchdog\" 2>/dev/null || true; wait \"$watchdog\" 2>/dev/null || true; wait \"$timer_supervisor\" 2>/dev/null || true; rm -f \"$payload\" \"$timer_stop\" \"$timer_done\""
        let noOp = stdinDrainingHookNoOpShellCommand
        return [
            "cmux_cli=\"${CMUX_BUNDLED_CLI_PATH:-}\"",
            "if [ -z \"$cmux_cli\" ] || [ ! -x \"$cmux_cli\" ]; then cmux_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi",
            "agent_pid=\"${CMUX_CODEX_PID:-${PPID:-}}\"",
            // The hook shell's immediate parent is the callback owner. Do not
            // reuse an inherited observation from an outer Codex process.
            "hook_pid=\"${PPID:-}\"",
            "if [ -n \"$CMUX_SURFACE_ID\" ] && [ \"$\(def.disableEnvVar)\" != \"1\" ] && [ -n \"$cmux_cli\" ]; then payload=\"$(mktemp \"${TMPDIR:-/tmp}/cmux-codex-hook.XXXXXX\" 2>/dev/null || mktemp -t cmux-codex-hook 2>/dev/null)\" || { \(noOp); exit 0; }; cat >\"$payload\" || true; if [ -n \"${CMUX_SOCKET_PATH:-}\" ]; then CMUX_CODEX_PID=\"$agent_pid\" CMUX_CODEX_HOOK_PID=\"$hook_pid\" nohup sh -c '\(runner)' cmux-codex-hook \"$payload\" \"$cmux_cli\" --socket \"$CMUX_SOCKET_PATH\" \(routedArguments) >/dev/null 2>&1 & else CMUX_CODEX_PID=\"$agent_pid\" CMUX_CODEX_HOOK_PID=\"$hook_pid\" nohup sh -c '\(runner)' cmux-codex-hook \"$payload\" \"$cmux_cli\" \(routedArguments) >/dev/null 2>&1 & fi; echo '{}'; else \(noOp); fi",
        ].joined(separator: "; ")
    }
}
