import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    /// Schedules the normal Codex Stop path after the final child exits.
    ///
    /// Native child hooks must acknowledge the lifecycle write quickly, so the
    /// larger notification/store projection runs in a detached CLI process.
    /// The child-stop marker lets that process skip legacy prompt-depth
    /// inference; the ledger itself remains the single settlement authority.
    func spawnDetachedCodexSettledStop(
        payload: String,
        environment: [String: String],
        telemetry: CLISocketSentryTelemetry
    ) {
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
            "nohup /bin/sh -c '\"$0\" hooks codex stop < \"$1\" >/dev/null 2>&1; rm -f \"$1\"' \"$0\" \"$1\" >/dev/null 2>&1 &",
            selfPath,
            payloadURL.path,
        ]
        var childEnvironment = environment
        childEnvironment["CMUX_CODEX_SETTLED_CHILD_STOP"] = "1"
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
    /// Live Codex sessions may still hold paths from another tagged build, and
    /// concurrent launches can briefly overlap script generation, so collection
    /// waits until no Codex process is running and leaves recent files alone.
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

        let newestRemovableDate = Date().addingTimeInterval(-60)
        for url in contents where !filenames.contains(url.lastPathComponent) {
            let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
            ])
            guard CodexHookScriptName(filename: url.lastPathComponent) != nil,
                  values?.isRegularFile == true,
                  let modificationDate = values?.contentModificationDate,
                  modificationDate < newestRemovableDate else {
                continue
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Conservatively detects sessions that may still reference an older hook generation.
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

    /// `cmux hooks codex sync-native-title`: a detached re-invocation spawned
    /// from the Codex Stop hook (see ``spawnDetachedCodexNativeTitleSync``),
    /// mirroring how `auto-name` is spawned from the same site. Tells the app
    /// to mirror Codex's own native thread title (`~/.codex/state_5.sqlite`)
    /// onto the panel's raw terminal title — cmux #11144. No transcript is
    /// read and no summarizer runs: Codex already computed this title itself.
    func runCodexNativeTitleSyncHook(
        commandArgs: [String],
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry
    ) {
        guard let sessionId = optionValue(commandArgs, name: "--session"),
              let workspaceId = optionValue(commandArgs, name: "--workspace"),
              let surfaceId = optionValue(commandArgs, name: "--surface"),
              !sessionId.isEmpty, !workspaceId.isEmpty, !surfaceId.isEmpty else {
            return
        }
        _ = try? client.sendV2(method: "surface.sync_codex_native_title", params: [
            "session_id": sessionId,
            "workspace_id": workspaceId,
            "panel_id": surfaceId
        ])
        telemetry.breadcrumb("codex-hook.native-title-sync.sent")
    }

    /// Spawns the native-title-sync pass detached, mirroring
    /// ``spawnDetachedAgentAutoName``'s spawn-and-briefly-wait shape so this
    /// short synchronous Stop hook never blocks on it. Unlike the auto-naming
    /// spawn, this is not gated on the opt-in Workspace Auto-Naming setting —
    /// it runs unconditionally at every Codex turn end, matching Claude's
    /// unconditional OSC-driven tab title updates.
    func spawnDetachedCodexNativeTitleSync(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        env: [String: String],
        telemetry: CLISocketSentryTelemetry
    ) {
        guard !sessionId.isEmpty, !workspaceId.isEmpty, !surfaceId.isEmpty else { return }
        let selfPath: String = {
            if let first = ProcessInfo.processInfo.arguments.first,
               first.hasPrefix("/"),
               FileManager.default.isExecutableFile(atPath: first) {
                return first
            }
            if let bundled = normalizedHookValue(env["CMUX_BUNDLED_CLI_PATH"]),
               FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
            return "cmux"
        }()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "\"$0\" hooks codex sync-native-title --session \"$1\" --workspace \"$2\" --surface \"$3\" </dev/null >/dev/null 2>&1 &",
            selfPath,
            sessionId,
            workspaceId,
            surfaceId
        ]
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            telemetry.breadcrumb("codex-hook.native-title-sync.spawn-failed")
            return
        }
        if ((try? waitForProcessExit(process, timeout: 1)) ?? false) == false {
            process.terminate()
        }
    }

    static func codexFireAndForgetAgentHookShellCommand(_ command: String, for def: AgentHookDef) -> String {
        let routedArguments = command.hasPrefix("cmux ") ? String(command.dropFirst("cmux ".count)) : command
        let runner = "payload=\"$1\"; shift; \"$@\" <\"$payload\" >/dev/null 2>&1 & child=\"$!\"; ( timer=; trap \"kill \\$timer 2>/dev/null || true; wait \\$timer 2>/dev/null || true; exit 0\" HUP INT TERM; sleep 30 & timer=\"$!\"; wait \"$timer\" 2>/dev/null || true; timer=; kill \"$child\" 2>/dev/null || true ) & watchdog=\"$!\"; wait \"$child\" 2>/dev/null || true; kill \"$watchdog\" 2>/dev/null || true; wait \"$watchdog\" 2>/dev/null || true; rm -f \"$payload\""
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
