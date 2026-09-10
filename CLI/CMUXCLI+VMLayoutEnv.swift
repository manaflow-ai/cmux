import Foundation

/// `cmux vm layout export|apply` and `cmux vm env set|ls|rm`: layouts as data, and a
/// per-machine environment, for cloud machines.
///
/// Layouts run the machine's own in-VM `cmux layout …` (web/services/vms/guestCli.ts)
/// over the existing `vm.exec` channel, exactly like `vm push` / `vm tools` do, so the
/// Mac CLI, an agent inside the machine, and a linked peer share ONE implementation of
/// "apply this layout" (the shared-behavior policy). Environment VALUES are different:
/// they are secrets, and `vm.exec` is a plaintext hop through the control plane and the
/// provider, so `vm env set` goes through the app's `vm.env_set`, which delivers them
/// over the machine's end-to-end link into the same shim's `cmux env receive`
/// (`CloudEnvDelivery`). `vm env ls|rm` carry names only and stay on exec.
///
/// The layout document is the declarative format `cmux new-workspace --layout`,
/// `cmux layout save/get/open`, and cmux.json already accept (`CmuxLayoutNode`), so a
/// layout authored once applies on this Mac or on a machine. The Mac validates the
/// document BEFORE anything touches the machine and names the offending JSON path;
/// the shim re-validates on its side (it is also reachable without a Mac).
extension CMUXCLI {
    static let vmLayoutUsage = String(localized: "cli.vm.layout.usage", defaultValue: """
        Usage:
          cmux vm layout export <machine> [<workspace-id|name>] [--raw]
                                                              Print a machine workspace's layout as a declarative layout
                                                              document — the same JSON `cmux new-workspace --layout`,
                                                              `cmux layout save/open`, and cmux.json use. Default: the
                                                              machine's focused workspace. --raw prints the daemon's own
                                                              LayoutDocument (exact pane/tab ids) instead.
          cmux vm layout apply <machine> (<file>|- | --from-saved <name>) [--workspace <workspace-id>|--name <name>] [--cwd <dir>] [--open]
                                                              Build panes, splits, and tabs on the machine from a layout
                                                              document: a file, stdin (-), or a layout saved on this Mac
                                                              (`cmux layout list`). Default: a NEW machine workspace named
                                                              after the document (--name overrides); --workspace targets an
                                                              existing EMPTY workspace. Terminal `command`s are typed into
                                                              login shells started in each surface's `cwd` (relative to
                                                              --cwd, default: the work user's home). --open then opens the workspace here
                                                              with the same geometry.

        Document (one of):
          {"pane": {"surfaces": [{"type": "terminal", "name": "tests", "command": "bun test", "cwd": "work/app"}]}}
          {"direction": "horizontal"|"vertical", "split": 0.6, "children": [<node>, <node>]}
          {"name": …, "cwd": …, "layout": <node>}      or      {"name": …, "workspace": {"cwd": …, "layout": <node>}}
        `horizontal` = side by side (first child left), `vertical` = stacked (first child top); `split` is the
        first child's share (0.1–0.9, default 0.5). Surface types: terminal (name, command, cwd, env),
        browser (url, name); project surfaces are Mac-only and skipped on a machine.
        Workspace ids come from `cmux vm tree`. Add --json for the raw result. Exit 2 = the document is invalid.
        """)

    static let vmEnvUsage = String(localized: "cli.vm.env.usage", defaultValue: """
        Usage:
          cmux vm env set <machine> KEY=VALUE [KEY2=VALUE2 …] [--from-file <.env>] [-]
                                                              Set environment variables for every terminal, agent, and
                                                              command cmux starts on the machine. They persist in
                                                              ~/.config/cmux/env on its durable volume (mode 0600) and are
                                                              sourced by login and interactive shells there. --from-file
                                                              and `-` (stdin) read KEY=VALUE lines (dotenv rules: blank
                                                              lines and # comments skipped, optional `export `, matching
                                                              quotes stripped) — prefer them over KEY=VALUE on the command
                                                              line so values stay out of your shell history and `ps`.
          cmux vm env ls <machine> [--show]                   List the variable names; --show prints the values too.
          cmux vm env rm <machine> KEY [KEY2 …]               Remove variables.

        How values travel: over the machine's cmux-tui link (end-to-end encrypted, brokered but never
        read by the control plane) into the machine's `cmux env receive`, which turns terminal echo
        off before it reads. Nothing passes through vm.exec, a command line, or a terminal's screen,
        and only names are ever printed back (use --show to see values). Forks, snapshots, and
        templates of the machine inherit the file; `cmux vm env rm` before you promote one.
        Keys match [A-Za-z_][A-Za-z0-9_]*. Add --json for the raw result.
        """)

    /// `vm.exec` budgets. Export is one snapshot read; apply spawns a handful of shells
    /// and waits for their prompts; the control plane caps a single exec at five minutes.
    static let vmLayoutExportExecTimeoutMs = 60_000
    static let vmLayoutApplyExecTimeoutMs = 120_000
    static let vmEnvExecTimeoutMs = 30_000

    // MARK: - vm layout

    func runVMLayoutCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        if rest.contains("--help") || rest.contains("-h") || rest.isEmpty {
            print(Self.vmLayoutUsage)
            return
        }
        let verb = rest[0]
        let tail = Array(rest.dropFirst())
        switch verb {
        case "export", "get", "show":
            try runVMLayoutExport(tail, client: client, jsonOutput: jsonOutput)
        case "apply", "set":
            try runVMLayoutApply(tail, client: client, jsonOutput: jsonOutput)
        default:
            throw CLIError(message: String(format: String(localized: "cli.vm.layout.unknownVerb", defaultValue: "vm layout: unknown verb '%1$@'\n\n%2$@"), String(describing: verb), String(describing: Self.vmLayoutUsage)))
        }
    }

    private func runVMLayoutExport(_ args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let raw = hasFlag(args, name: "--raw")
        let known: Set<String> = ["--raw", "--json"]
        if let unknown = args.first(where: { $0.hasPrefix("-") && !known.contains($0) }) {
            throw CLIError(message: String(format: String(localized: "cli.vm.layout.exportUnknownFlag", defaultValue: "vm layout export: unknown flag '%1$@'\n\n%2$@"), String(describing: unknown), String(describing: Self.vmLayoutUsage)))
        }
        let positional = args.filter { !$0.hasPrefix("-") }
        guard let machine = positional.first, !machine.isEmpty, positional.count <= 2 else {
            throw CLIError(message: Self.vmLayoutUsage)
        }
        let workspace = positional.count == 2 ? positional[1] : nil
        let result = try runVMShim(
            Self.vmLayoutExportCommand(workspace: workspace, raw: raw),
            machine: machine,
            client: client,
            timeoutMs: Self.vmLayoutExportExecTimeoutMs,
            feature: "layout"
        )
        // The shim prints JSON in both modes. Pass it through untouched, so what an
        // agent sees is exactly what `cmux vm layout apply … -` (or `cmux layout save`
        // on this Mac) accepts.
        Self.printVerbatim(result.stdout)
    }

    private func runVMLayoutApply(_ args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (workspaceOpt, r1) = parseOption(args, name: "--workspace")
        let (nameOpt, r2) = parseOption(r1, name: "--name")
        let (cwdOpt, r3) = parseOption(r2, name: "--cwd")
        let (savedOpt, r4) = parseOption(r3, name: "--from-saved")
        if workspaceOpt != nil, nameOpt != nil {
            throw CLIError(message: Self.vmLayoutUsage, exitCode: 2)
        }
        let open = hasFlag(r4, name: "--open")
        let known: Set<String> = ["--open", "--json"]
        if let unknown = r4.first(where: { $0.hasPrefix("-") && $0 != "-" && !known.contains($0) }) {
            throw CLIError(message: String(format: String(localized: "cli.vm.layout.applyUnknownFlag", defaultValue: "vm layout apply: unknown flag '%1$@'\n\n%2$@"), String(describing: unknown), String(describing: Self.vmLayoutUsage)))
        }
        // `-` (stdin) is the one dash-led positional.
        let positional = r4.filter { !$0.hasPrefix("-") || $0 == "-" }
        guard let machine = positional.first, !machine.isEmpty, positional.count <= 2 else {
            throw CLIError(message: Self.vmLayoutUsage)
        }
        let source = positional.count == 2 ? positional[1] : nil
        if source != nil, savedOpt != nil {
            throw CLIError(message: String(format: String(localized: "cli.vm.layout.applyPassAFileOrORFromSaved", defaultValue: "vm layout apply: pass a file (or -) OR --from-saved <name>, not both\n\n%1$@"), String(describing: Self.vmLayoutUsage)))
        }

        let documentData = try readVMLayoutDocument(source: source, savedName: savedOpt, client: client)
        // Validate on this side first: a bad document never costs a round trip to the
        // machine, and the error names the exact JSON path instead of a shim message.
        let document: VMLayoutDocument
        do {
            document = try Self.parseVMLayoutDocument(documentData)
        } catch let error as VMLayoutDocumentError {
            throw CLIError(message: String(format: String(localized: "cli.vm.layout.applyInvalidLayoutDocument", defaultValue: "vm layout apply: invalid layout document: %1$@"), String(describing: error.description)), exitCode: 2)
        }

        let result = try runVMShim(
            Self.vmLayoutApplyCommand(documentJSON: documentData, workspace: workspaceOpt, name: nameOpt, cwd: cwdOpt),
            machine: machine,
            client: client,
            timeoutMs: Self.vmLayoutApplyExecTimeoutMs,
            feature: "layout"
        )
        let payload = Self.jsonObject(fromShimOutput: result.stdout)
        let remoteWorkspace = (payload?["workspace_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        var openedPayload: [String: Any]?
        if open {
            guard let remoteWorkspace else {
                throw CLIError(message: String(format: String(localized: "cli.vm.layout.applyTheLayoutWasAppliedButTheMachine", defaultValue: "vm layout apply: the layout was applied but the machine reported no workspace id to open (output: %1$@)"), String(describing: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))))
            }
            openedPayload = try openAppliedVMWorkspace(machine: machine, remoteWorkspace: remoteWorkspace, client: client)
        }

        if jsonOutput {
            var out: [String: Any] = payload ?? ["stdout": result.stdout]
            out["machine"] = machine
            if let openedPayload { out["opened"] = openedPayload }
            print(jsonString(out))
            return
        }
        for warning in (payload?["warnings"] as? [String]) ?? [] {
            cliWriteStderr("warning: \(warning)\n")
        }
        if let payload {
            let panes = (payload["panes"] as? [[String: Any]]) ?? []
            let surfaces = panes.reduce(0) { $0 + (($1["surfaces"] as? [[String: Any]])?.count ?? 0) }
            let name = (payload["workspace_name"] as? String) ?? nameOpt ?? document.name ?? ""
            print("OK workspace=\(remoteWorkspace ?? "?") name=\(name) panes=\(panes.count) surfaces=\(surfaces) machine=\(machine)")
        } else {
            // An older or unexpected shim reply: show what it said rather than guessing.
            Self.printVerbatim(result.stdout)
        }
        if let openedPayload {
            let local = (openedPayload["workspace_id"] as? String) ?? "?"
            let opened = (openedPayload["opened"] as? Int) ?? 0
            print("OK opened workspace=\(local) opened=\(opened) machine=\(machine)")
        } else if let remoteWorkspace {
            print(String(format: String(localized: "cli.vm.layoutEnv.openItCmuxVmWorkspaceOpenValueValue", defaultValue: "Open it: cmux vm workspace open %1$@ %2$@"), String(describing: machine), String(describing: remoteWorkspace)))
        }
    }

    /// How long `--open` keeps trying before handing the human the manual command.
    static let vmLayoutOpenAttempts = 5
    static let vmLayoutOpenRetryDelay: TimeInterval = 1

    /// The geometry-honoring open (`vm.workspace_open`, the same method the sidebar row
    /// and `cmux vm workspace open` use) for a workspace the shim built moments ago.
    /// The Mac catalog learns about that workspace from the daemon's event stream,
    /// which can lag the exec: re-sync the machine first (`vm.tree {refresh}`), then
    /// open; a not-found or still-empty answer is retried briefly so a slow link never
    /// turns a successful apply into a failure. Other errors propagate untouched.
    private func openAppliedVMWorkspace(machine: String, remoteWorkspace: String, client: SocketClient) throws -> [String: Any] {
        _ = try client.sendV2(method: "vm.tree", params: ["id": machine, "refresh": true], responseTimeout: 120)
        var lastFailure = ""
        for attempt in 1...Self.vmLayoutOpenAttempts {
            do {
                let payload = try client.sendV2(
                    method: "vm.workspace_open",
                    params: ["id": machine, "workspace_id": remoteWorkspace],
                    responseTimeout: 240
                )
                let opened = (payload["opened"] as? Int) ?? 0
                let empty = (payload["empty"] as? Bool) ?? false
                if opened > 0, !empty { return payload }
                lastFailure = empty
                    ? "the Mac still sees workspace \(remoteWorkspace) as empty"
                    : "nothing opened"
            } catch let error as CLIError where Self.vmWorkspaceNotYetVisible(error) {
                lastFailure = error.message
            }
            if attempt < Self.vmLayoutOpenAttempts {
                Thread.sleep(forTimeInterval: Self.vmLayoutOpenRetryDelay)
            }
        }
        throw CLIError(message: String(format: String(localized: "cli.vm.layout.applyTheLayoutIsAppliedToWorkspace", defaultValue: "vm layout apply: the layout is applied to workspace %1$@ on %2$@, but it could not be opened here yet (%3$@). Open it with: cmux vm workspace open %4$@ %5$@"), String(describing: remoteWorkspace), String(describing: machine), String(describing: lastFailure), String(describing: machine), String(describing: remoteWorkspace)))
    }

    /// The transient shapes of "the catalog has not caught up": a not-found code, or
    /// the catalog's destinationNotFound / no-such-workspace wording.
    static func vmWorkspaceNotYetVisible(_ error: CLIError) -> Bool {
        if error.v2Code == "not_found" || error.v2Code == "not_ready" { return true }
        let text = error.message.lowercased()
        return text.contains("destinationnotfound")
            || text.contains("not found")
            || text.contains("no such workspace")
            || text.contains("unknown workspace")
    }

    /// The document bytes `apply` sends: a file, stdin, or a layout saved on this Mac
    /// (`layout.get`, the same store `cmux layout get` reads). Read verbatim — the shim
    /// understands every wrapper — so what the machine builds is what the caller wrote.
    private func readVMLayoutDocument(source: String?, savedName: String?, client: SocketClient) throws -> Data {
        if let savedName {
            let trimmed = savedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw CLIError(message: String(localized: "cli.vm.layout.applyFromSavedNeedsALayoutNameSee", defaultValue: "vm layout apply: --from-saved needs a layout name (see `cmux layout list`)"))
            }
            let payload = try client.sendV2(method: "layout.get", params: ["name": trimmed])
            guard JSONSerialization.isValidJSONObject(payload) else {
                throw CLIError(message: String(format: String(localized: "cli.vm.layout.applySavedLayoutCouldNotBeEncoded", defaultValue: "vm layout apply: saved layout %1$@ could not be encoded"), String(describing: trimmed)))
            }
            return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        }
        if let source, source != "-" {
            let path = resolvePath(source)
            guard let data = FileManager.default.contents(atPath: path) else {
                throw CLIError(message: String(format: String(localized: "cli.vm.layout.applyCannotRead", defaultValue: "vm layout apply: cannot read %1$@"), String(describing: path)))
            }
            return data
        }
        if source == nil, isatty(FileHandle.standardInput.fileDescriptor) != 0 {
            throw CLIError(message: String(format: String(localized: "cli.vm.layout.applyGiveALayoutFileForStdinOr", defaultValue: "vm layout apply: give a layout file, `-` for stdin, or --from-saved <name>\n\n%1$@"), String(describing: Self.vmLayoutUsage)))
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else {
            throw CLIError(message: String(localized: "cli.vm.layout.applyEmptyLayoutDocumentOnStdin", defaultValue: "vm layout apply: empty layout document on stdin"), exitCode: 2)
        }
        return data
    }

    // MARK: - vm env

    func runVMEnvCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        if rest.contains("--help") || rest.contains("-h") || rest.isEmpty {
            print(Self.vmEnvUsage)
            return
        }
        let verb = rest[0]
        let tail = Array(rest.dropFirst()).filter { $0 != "--json" }
        switch verb {
        case "set", "add":
            let (machine, sources) = try Self.vmEnvSetInputs(tail)
            var assignments: [VMEnvAssignment] = []
            do {
                for source in sources {
                    switch source {
                    case .assignment(let raw):
                        assignments.append(try Self.parseVMEnvAssignment(raw))
                    case .file(let file):
                        let path = resolvePath(file)
                        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
                            throw CLIError(message: String(format: String(localized: "cli.vm.env.setCannotRead", defaultValue: "vm env set: cannot read %1$@"), String(describing: path)))
                        }
                        assignments += try Self.parseVMEnvFile(text)
                    case .standardInput:
                        let data = FileHandle.standardInput.readDataToEndOfFile()
                        guard let text = String(data: data, encoding: .utf8) else {
                            throw VMEnvError(description: String(localized: "cli.vm.layoutEnv.stdinIsNotUTF8Text", defaultValue: "stdin is not UTF-8 text"))
                        }
                        assignments += try Self.parseVMEnvFile(text)
                    }
                }
            } catch let error as VMEnvError {
                throw CLIError(message: String(format: String(localized: "cli.vm.env.set", defaultValue: "vm env set: %1$@"), String(describing: error.description)), exitCode: 2)
            }
            guard !assignments.isEmpty else {
                throw CLIError(message: String(format: String(localized: "cli.vm.env.setGiveKEYVALUEPairsFromFileEnv", defaultValue: "vm env set: give KEY=VALUE pairs, --from-file <.env>, or - for stdin\n\n%1$@"), String(describing: Self.vmEnvUsage)), exitCode: 2)
            }
            let merged = Self.mergedVMEnvAssignments(assignments)
            // Values go to the app over the local socket and from there over the machine's
            // link into `cmux env receive` (CloudEnvDelivery) — never `vm.exec`, never argv on
            // the machine, never a visible screen. The app answers with names only.
            let response = try client.sendV2(
                method: "vm.env_set",
                params: Self.vmEnvSetParams(machine: machine, assignments: merged),
                responseTimeout: 200
            )
            let keys = merged.map(\.key)
            if jsonOutput {
                var out = response
                out["machine"] = machine
                out["keys"] = keys
                print(jsonString(out))
                return
            }
            // Names only: a value is a secret until proven otherwise.
            let format = keys.count == 1
                ? String(localized: "cli.vm.env.set.one", defaultValue: "OK set %1$ld variable on %2$@: %3$@")
                : String(localized: "cli.vm.env.set.many", defaultValue: "OK set %1$ld variables on %2$@: %3$@")
            print(String(format: format, keys.count, machine, keys.joined(separator: ", ")))

        case "ls", "list":
            let show = hasFlag(tail, name: "--show")
            let known: Set<String> = ["--show"]
            if let unknown = tail.first(where: { $0.hasPrefix("-") && !known.contains($0) }) {
                throw CLIError(message: String(format: String(localized: "cli.vm.env.lsUnknownFlag", defaultValue: "vm env ls: unknown flag '%1$@'\n\n%2$@"), String(describing: unknown), String(describing: Self.vmEnvUsage)))
            }
            let positional = tail.filter { !$0.hasPrefix("-") }
            guard let machine = positional.first, !machine.isEmpty, positional.count == 1 else {
                throw CLIError(message: Self.vmEnvUsage)
            }
            let result = try runVMShim(
                Self.vmEnvListCommand(show: show, json: jsonOutput),
                machine: machine,
                client: client,
                timeoutMs: Self.vmEnvExecTimeoutMs,
                feature: "env"
            )
            Self.printVerbatim(result.stdout)

        case "rm", "remove", "unset":
            if let unknown = tail.first(where: { $0.hasPrefix("-") }) {
                throw CLIError(message: String(format: String(localized: "cli.vm.env.rmUnknownFlag", defaultValue: "vm env rm: unknown flag '%1$@'\n\n%2$@"), String(describing: unknown), String(describing: Self.vmEnvUsage)))
            }
            guard let machine = tail.first, !machine.isEmpty else { throw CLIError(message: Self.vmEnvUsage) }
            let keys = Array(tail.dropFirst())
            guard !keys.isEmpty else {
                throw CLIError(message: String(format: String(localized: "cli.vm.env.rmGiveAtLeastOneKEY", defaultValue: "vm env rm: give at least one KEY\n\n%1$@"), String(describing: Self.vmEnvUsage)), exitCode: 2)
            }
            if let bad = keys.first(where: { !Self.isValidVMEnvKey($0) }) {
                throw CLIError(message: String(format: String(localized: "cli.vm.env.rmInvalidVariableNameKeysMatchA", defaultValue: "vm env rm: invalid variable name '%1$@' (keys match [A-Za-z_][A-Za-z0-9_]*)"), String(describing: bad)), exitCode: 2)
            }
            let result = try runVMShim(
                Self.vmEnvRemoveCommand(keys: keys),
                machine: machine,
                client: client,
                timeoutMs: Self.vmEnvExecTimeoutMs,
                feature: "env"
            )
            if jsonOutput {
                print(jsonString(["machine": machine, "keys": keys, "stdout": result.stdout]))
                return
            }
            if result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let format = keys.count == 1
                    ? String(localized: "cli.vm.env.remove.one", defaultValue: "OK removed %1$ld variable on %2$@: %3$@")
                    : String(localized: "cli.vm.env.remove.many", defaultValue: "OK removed %1$ld variables on %2$@: %3$@")
                print(String(format: format, keys.count, machine, keys.joined(separator: ", ")))
            } else {
                Self.printVerbatim(result.stdout)
            }

        case "path":
            guard let machine = tail.first, !machine.isEmpty else { throw CLIError(message: Self.vmEnvUsage) }
            let result = try runVMShim("cmux env path", machine: machine, client: client, timeoutMs: Self.vmEnvExecTimeoutMs, feature: "env")
            Self.printVerbatim(result.stdout)

        default:
            throw CLIError(message: String(format: String(localized: "cli.vm.env.unknownVerb", defaultValue: "vm env: unknown verb '%1$@'\n\n%2$@"), String(describing: verb), String(describing: Self.vmEnvUsage)))
        }
    }

    // MARK: - Running the in-VM shim

    struct VMShimResult {
        let exitCode: Int
        let stdout: String
        let stderr: String
    }

    /// One `vm.exec` of the machine's `cmux` shim. A non-zero exit becomes a CLIError
    /// carrying the shim's own message and exit status (2 = it rejected the input), and
    /// a shim too old to know the verb is explained instead of surfacing cmux-tui's
    /// "unknown resource scope" (the shim falls through to the daemon binary for
    /// unknown words). The shim's stderr (warnings) is forwarded on success.
    private func runVMShim(
        _ command: String,
        machine: String,
        client: SocketClient,
        timeoutMs: Int,
        feature: String
    ) throws -> VMShimResult {
        let response = try client.sendV2(
            method: "vm.exec",
            params: ["id": machine, "command": command, "timeout_ms": timeoutMs],
            responseTimeout: TimeInterval(timeoutMs) / 1000 + 30
        )
        let stdout = (response["stdout"] as? String) ?? ""
        let stderr = (response["stderr"] as? String) ?? ""
        let exitCode = (response["exit_code"] as? Int) ?? -1
        if Self.vmShimPredatesSupport(stdout: stdout, stderr: stderr) {
            throw CLIError(message: Self.vmShimOutdatedMessage(machine: machine, feature: feature))
        }
        if exitCode != 0 {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = detail.isEmpty ? (fallback.isEmpty ? String(format: String(localized: "cli.vm.layoutEnv.cmuxValueFailedOnValueExitValue", defaultValue: "cmux %1$@ failed on %2$@ (exit %3$@)"), String(describing: feature), String(describing: machine), String(describing: exitCode)) : fallback) : detail
            // The shim's exit status is part of its contract (2 = bad input); pass the
            // small ones through, and never let a timeout's 124 masquerade as ours.
            let passthrough: Int32 = (1...3).contains(exitCode) ? Int32(exitCode) : 1
            throw CLIError(message: text, exitCode: passthrough)
        }
        if !stderr.isEmpty {
            cliWriteStderr(stderr.hasSuffix("\n") ? stderr : stderr + "\n")
        }
        return VMShimResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }

    private static func printVerbatim(_ text: String) {
        guard !text.isEmpty else { return }
        print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
    }

    // MARK: - Pure helpers (no socket; shared by the verbs above and the tests)

    /// cmux-tui answers an unknown resource word with `unknown resource scope "…"`, and
    /// the shim's peer dispatcher with `unknown vm subcommand`. Either one after
    /// `cmux layout` / `cmux env` means the machine's shim predates the verb.
    static func vmShimPredatesSupport(stdout: String, stderr: String) -> Bool {
        let text = stdout + "\n" + stderr
        return text.contains("unknown resource scope") || text.contains("unknown vm subcommand")
    }

    static func vmShimOutdatedMessage(machine: String, feature: String) -> String {
        String(format: String(localized: "cli.vm.layoutEnv.thisMachineSCmuxShimPredatesValueSupportReconnectIt", defaultValue: "this machine's cmux shim predates %1$@ support — reconnect it (cmux vm tree %2$@ --refresh) to heal, then retry"), String(describing: feature), String(describing: machine))
    }

    /// `cmux layout export --json [--workspace <ws>] [--raw]`, run on the machine.
    static func vmLayoutExportCommand(workspace: String?, raw: Bool) -> String {
        var argv = ["cmux", "layout", "export", "--json"]
        if let workspace, !workspace.isEmpty { argv += ["--workspace", workspace] }
        if raw { argv.append("--raw") }
        return argv.map(vmShimShellQuote).joined(separator: " ")
    }

    /// The document travels as base64 inside the command line and is piped into the
    /// shim's stdin: no temp file on the machine, no quoting of user JSON in a shell,
    /// and the same framing `vm push` uses.
    static func vmLayoutApplyCommand(documentJSON: Data, workspace: String?, name: String?, cwd: String?, reuse: Bool = false) -> String {
        var argv = ["cmux", "layout", "apply", "--json"]
        if reuse { argv.append("--reuse") }
        if let workspace, !workspace.isEmpty { argv += ["--workspace", workspace] }
        if let name, !name.isEmpty { argv += ["--name", name] }
        if let cwd, !cwd.isEmpty { argv += ["--cwd", cwd] }
        argv.append("-")
        return "printf %s '\(documentJSON.base64EncodedString())' | base64 -d | " + argv.map(vmShimShellQuote).joined(separator: " ")
    }

    /// The `vm.env_set` request: entries as typed `{key, value}` objects. Values cross
    /// only the authenticated local socket here; the app forwards them over the machine
    /// link (see `CloudEnvDelivery`).
    static func vmEnvSetParams(machine: String, assignments: [VMEnvAssignment]) -> [String: Any] {
        [
            "id": machine,
            "entries": assignments.map { ["key": $0.key, "value": $0.value] },
        ]
    }

    static func vmEnvListCommand(show: Bool, json: Bool) -> String {
        var argv = ["cmux", "env", "ls"]
        if show { argv.append("--show") }
        if json { argv.append("--json") }
        return argv.joined(separator: " ")
    }

    static func vmEnvRemoveCommand(keys: [String]) -> String {
        (["cmux", "env", "rm"] + keys).map(vmShimShellQuote).joined(separator: " ")
    }

    /// Later assignments win, like a shell; order of first appearance is kept.
    static func mergedVMEnvAssignments(_ assignments: [VMEnvAssignment]) -> [VMEnvAssignment] {
        var order: [String] = []
        var values: [String: String] = [:]
        for assignment in assignments {
            if values[assignment.key] == nil { order.append(assignment.key) }
            values[assignment.key] = assignment.value
        }
        return order.map { VMEnvAssignment(key: $0, value: values[$0] ?? "") }
    }

    struct VMEnvAssignment: Equatable {
        let key: String
        let value: String
    }

    struct VMEnvError: Error, CustomStringConvertible {
        let description: String
    }

    static func isValidVMEnvKey(_ key: String) -> Bool {
        key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }

    /// One argv `KEY=VALUE`. The value is taken literally (it already went through the
    /// caller's shell); it may be empty, never multi-line.
    static func parseVMEnvAssignment(_ raw: String) throws -> VMEnvAssignment {
        guard let separator = raw.firstIndex(of: "=") else {
            throw VMEnvError(description: String(format: String(localized: "cli.vm.layoutEnv.expectedKEYVALUEGotValue", defaultValue: "expected KEY=VALUE, got '%1$@'"), String(describing: raw)))
        }
        let key = String(raw[..<separator])
        let value = String(raw[raw.index(after: separator)...])
        guard isValidVMEnvKey(key) else {
            throw VMEnvError(description: String(format: String(localized: "cli.vm.layoutEnv.invalidVariableNameValueKeysMatchAZaZA", defaultValue: "invalid variable name '%1$@' (keys match [A-Za-z_][A-Za-z0-9_]*)"), String(describing: key)))
        }
        guard !value.contains("\n"), !value.contains("\r") else {
            throw VMEnvError(description: String(format: String(localized: "cli.vm.layoutEnv.valueOfValueMustBeASingleLine", defaultValue: "value of %1$@ must be a single line"), String(describing: key)))
        }
        return VMEnvAssignment(key: key, value: value)
    }

    enum VMEnvInputSource: Equatable {
        case assignment(String)
        case file(String)
        case standardInput
    }

    static func vmEnvSetInputs(_ arguments: [String]) throws -> (machine: String, sources: [VMEnvInputSource]) {
        var machine: String?
        var sources: [VMEnvInputSource] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--from-file" {
                guard index + 1 < arguments.count, !arguments[index + 1].isEmpty else {
                    throw CLIError(message: vmEnvUsage, exitCode: 2)
                }
                sources.append(.file(arguments[index + 1]))
                index += 2
                continue
            }
            if argument.hasPrefix("--from-file=") {
                let path = String(argument.dropFirst("--from-file=".count))
                guard !path.isEmpty else { throw CLIError(message: vmEnvUsage, exitCode: 2) }
                sources.append(.file(path))
            } else if argument == "-" {
                sources.append(.standardInput)
            } else if argument.hasPrefix("-") {
                throw CLIError(message: String(format: String(localized: "cli.vm.env.setUnknownFlag", defaultValue: "vm env set: unknown flag '%1$@'\n\n%2$@"), String(describing: argument), String(describing: vmEnvUsage)))
            } else if machine == nil {
                machine = argument
            } else {
                sources.append(.assignment(argument))
            }
            index += 1
        }
        guard let machine, !machine.isEmpty else { throw CLIError(message: vmEnvUsage) }
        return (machine, sources)
    }

    static func parseVMEnvFileValue(_ value: String) -> String {
        if let quote = value.first, quote == "\"" || quote == "'" {
            var escaped = false
            for index in value.indices.dropFirst() {
                let character = value[index]
                if character == quote, !escaped {
                    let suffix = value[value.index(after: index)...].trimmingCharacters(in: .whitespaces)
                    if suffix.isEmpty || suffix.hasPrefix("#") {
                        return String(value[value.index(after: value.startIndex)..<index])
                    }
                }
                escaped = character == "\\" && !escaped
            }
        }
        if let comment = value.range(of: "[ \\t]+#", options: .regularExpression) {
            return value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    /// dotenv, the common subset: blank lines and `#` comments skipped, optional
    /// `export `, `KEY=VALUE`, a matching pair of surrounding quotes stripped (no escape
    /// processing), trailing comments outside the quotes dropped. Line numbers are
    /// reported so a bad file is fixable.
    static func parseVMEnvFile(_ text: String) throws -> [VMEnvAssignment] {
        var assignments: [VMEnvAssignment] = []
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") || line.hasPrefix("export\t") {
                line = String(line.dropFirst("export".count)).trimmingCharacters(in: .whitespaces)
            }
            guard let separator = line.firstIndex(of: "=") else {
                throw VMEnvError(description: String(format: String(localized: "cli.vm.layoutEnv.lineValueExpectedKEYVALUEGotValue", defaultValue: "line %1$@: expected KEY=VALUE, got '%2$@'"), String(describing: index + 1), String(describing: rawLine.trimmingCharacters(in: .whitespaces))))
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard isValidVMEnvKey(key) else {
                throw VMEnvError(description: String(format: String(localized: "cli.vm.layoutEnv.lineValueInvalidVariableNameValueKeysMatchAZa", defaultValue: "line %1$@: invalid variable name '%2$@' (keys match [A-Za-z_][A-Za-z0-9_]*)"), String(describing: index + 1), String(describing: key)))
            }
            let rawValue = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            let value = parseVMEnvFileValue(rawValue)
            assignments.append(VMEnvAssignment(key: key, value: value))
        }
        return assignments
    }

    struct VMLayoutDocumentError: Error, CustomStringConvertible {
        let path: String
        let reason: String
        var description: String {
            String(format: String(localized: "cli.vm.layout.documentError", defaultValue: "%1$@ at %2$@"), reason, path)
        }
    }

    /// A validated document: the layout node, where it sat in the wrapper, and the
    /// wrapper's name/cwd (informational — the shim reads the same wrapper itself).
    struct VMLayoutDocument {
        let node: [String: Any]
        let nodePath: String
        let name: String?
        let cwd: String?
    }

    static func parseVMLayoutDocument(_ data: Data) throws -> VMLayoutDocument {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw VMLayoutDocumentError(path: "$", reason: String(localized: "cli.vm.layoutEnv.notValidJSON", defaultValue: "not valid JSON"))
        }
        guard let root = object as? [String: Any] else {
            throw VMLayoutDocumentError(path: "$", reason: String(localized: "cli.vm.layoutEnv.layoutDocumentMustBeAJSONObject", defaultValue: "layout document must be a JSON object"))
        }
        let document = try vmLayoutDocumentNode(root)
        try validateVMLayoutNode(document.node, path: document.nodePath)
        return document
    }

    /// The three accepted shapes: a bare node, `{"layout": node, …}` (a workspace
    /// definition), and `{"workspace": {"layout": node, …}, …}` (what `cmux layout get`
    /// prints for a saved layout).
    static func vmLayoutDocumentNode(_ root: [String: Any]) throws -> VMLayoutDocument {
        if root["pane"] != nil || root["direction"] != nil {
            return VMLayoutDocument(node: root, nodePath: "$", name: nil, cwd: nil)
        }
        if let layout = root["layout"] {
            guard let node = layout as? [String: Any] else {
                throw VMLayoutDocumentError(path: "$.layout", reason: String(localized: "cli.vm.layoutEnv.layoutMustBeALayoutNodeObject", defaultValue: "'layout' must be a layout node object"))
            }
            return VMLayoutDocument(node: node, nodePath: "$.layout", name: root["name"] as? String, cwd: root["cwd"] as? String)
        }
        if let workspace = root["workspace"] as? [String: Any], let layout = workspace["layout"] {
            guard let node = layout as? [String: Any] else {
                throw VMLayoutDocumentError(path: "$.workspace.layout", reason: String(localized: "cli.vm.layoutEnv.layoutMustBeALayoutNodeObject", defaultValue: "'layout' must be a layout node object"))
            }
            return VMLayoutDocument(
                node: node,
                nodePath: "$.workspace.layout",
                name: (root["name"] as? String) ?? (workspace["name"] as? String),
                cwd: workspace["cwd"] as? String
            )
        }
        throw VMLayoutDocumentError(
            path: "$",
            reason: String(localized: "cli.vm.layoutEnv.noLayoutFoundExpectedANodePaneOrDirectionLayout", defaultValue: "no layout found: expected a node ({\"pane\": …} or {\"direction\": …}), {\"layout\": <node>}, or {\"workspace\": {\"layout\": <node>}}")
        )
    }

    static let vmLayoutSurfaceTypes: Set<String> = ["terminal", "browser", "project"]
    static let vmLayoutSplitDirections: Set<String> = ["horizontal", "vertical"]

    /// Mirrors `CmuxLayoutNode`'s decoder (Sources/CmuxConfig.swift): exactly one of
    /// `pane` / `direction`, splits have exactly two children, panes at least one
    /// surface, every surface a known type. Unknown sibling keys are allowed, as Codable
    /// allows them on the Mac.
    static func validateVMLayoutNode(_ value: Any, path: String) throws {
        guard let node = value as? [String: Any] else {
            throw VMLayoutDocumentError(path: path, reason: String(localized: "cli.vm.layoutEnv.layoutNodeMustBeAnObject", defaultValue: "layout node must be an object"))
        }
        let hasPane = node["pane"] != nil
        let hasDirection = node["direction"] != nil
        if hasPane && hasDirection {
            throw VMLayoutDocumentError(path: path, reason: String(localized: "cli.vm.layoutEnv.layoutNodeMustNotHaveBothPaneAndDirection", defaultValue: "layout node must not have both 'pane' and 'direction'"))
        }
        if !hasPane && !hasDirection {
            throw VMLayoutDocumentError(path: path, reason: String(localized: "cli.vm.layoutEnv.layoutNodeNeedsPaneALeafOrDirectionASplit", defaultValue: "layout node needs 'pane' (a leaf) or 'direction' (a split)"))
        }
        if hasPane {
            guard let pane = node["pane"] as? [String: Any] else {
                throw VMLayoutDocumentError(path: "\(path).pane", reason: String(localized: "cli.vm.layoutEnv.paneMustBeAnObject", defaultValue: "'pane' must be an object"))
            }
            guard let surfaces = pane["surfaces"] as? [Any], !surfaces.isEmpty else {
                throw VMLayoutDocumentError(path: "\(path).pane.surfaces", reason: String(localized: "cli.vm.layoutEnv.surfacesMustBeANonEmptyArray", defaultValue: "'surfaces' must be a non-empty array"))
            }
            for (index, raw) in surfaces.enumerated() {
                try validateVMLayoutSurface(raw, path: "\(path).pane.surfaces[\(index)]")
            }
            return
        }
        guard let direction = node["direction"] as? String, vmLayoutSplitDirections.contains(direction) else {
            throw VMLayoutDocumentError(path: "\(path).direction", reason: String(localized: "cli.vm.layoutEnv.directionMustBeHorizontalOrVertical", defaultValue: "'direction' must be \"horizontal\" or \"vertical\""))
        }
        if let split = node["split"], !(split is NSNull) {
            // JSON booleans arrive as NSNumber too; only the CF type id tells them apart.
            guard let number = split as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite,
                  (0.1...0.9).contains(number.doubleValue) else {
                throw VMLayoutDocumentError(path: "\(path).split", reason: String(localized: "cli.vm.layoutEnv.splitMustBeANumberTheFirstChildSShare", defaultValue: "'split' must be a number (the first child's share, 0.1–0.9)"))
            }
        }
        guard let children = node["children"] as? [Any] else {
            throw VMLayoutDocumentError(path: "\(path).children", reason: String(localized: "cli.vm.layoutEnv.childrenMustBeAnArrayOfExactly2LayoutNodes", defaultValue: "'children' must be an array of exactly 2 layout nodes"))
        }
        guard children.count == 2 else {
            throw VMLayoutDocumentError(path: "\(path).children", reason: String(format: String(localized: "cli.vm.layoutEnv.splitNeedsExactly2ChildrenGotValue", defaultValue: "split needs exactly 2 children (got %1$@)"), String(describing: children.count)))
        }
        for (index, child) in children.enumerated() {
            try validateVMLayoutNode(child, path: "\(path).children[\(index)]")
        }
    }

    private static func validateVMLayoutSurface(_ value: Any, path: String) throws {
        guard let surface = value as? [String: Any] else {
            throw VMLayoutDocumentError(path: path, reason: String(localized: "cli.vm.layoutEnv.surfaceMustBeAnObject", defaultValue: "surface must be an object"))
        }
        guard let type = surface["type"] as? String, vmLayoutSurfaceTypes.contains(type) else {
            throw VMLayoutDocumentError(path: "\(path).type", reason: String(localized: "cli.vm.layoutEnv.typeMustBeTerminalBrowserOrProject", defaultValue: "'type' must be \"terminal\", \"browser\", or \"project\""))
        }
        for key in ["name", "command", "cwd", "url"] {
            if let raw = surface[key], !(raw is NSNull), !(raw is String) {
                throw VMLayoutDocumentError(path: "\(path).\(key)", reason: String(format: String(localized: "cli.vm.layoutEnv.valueMustBeAString", defaultValue: "'%1$@' must be a string"), String(describing: key)))
            }
        }
        if type == "browser", (surface["url"] as? String)?.isEmpty != false {
            throw VMLayoutDocumentError(path: "\(path).url", reason: String(localized: "cli.vm.layoutEnv.browserSurfaceNeedsUrl", defaultValue: "browser surface needs url"))
        }
        if let env = surface["env"], !(env is NSNull) {
            guard let table = env as? [String: Any], table.values.allSatisfy({ $0 is String }) else {
                throw VMLayoutDocumentError(path: "\(path).env", reason: String(localized: "cli.vm.layoutEnv.envMustBeAnObjectOfStringValues", defaultValue: "'env' must be an object of string values"))
            }
            if let bad = table.keys.first(where: { !isValidVMEnvKey($0) }) {
                throw VMLayoutDocumentError(path: "\(path).env.\(bad)", reason: String(format: String(localized: "cli.vm.layoutEnv.invalidVariableNameValueKeysMatchAZaZA", defaultValue: "invalid variable name '%1$@' (keys match [A-Za-z_][A-Za-z0-9_]*)"), String(describing: bad)))
            }
        }
        if let focus = surface["focus"], !(focus is NSNull) {
            guard let number = focus as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw VMLayoutDocumentError(path: "\(path).focus", reason: String(localized: "cli.vm.layoutEnv.focusMustBeTrueOrFalse", defaultValue: "'focus' must be true or false"))
            }
        }
    }

    static func jsonObject(fromShimOutput text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The instance `shellQuote` rules, as a static so the pure command builders (and
    /// their tests) need no CLI instance: bare when safe, else single-quoted.
    static func vmShimShellQuote(_ value: String) -> String {
        let safePattern = "^[A-Za-z0-9_@%+=:,./-]+$"
        if value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
