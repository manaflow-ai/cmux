import Darwin
import Foundation

/// `cmux vm secrets …` (alias `cmux secrets …`): the Cloud Secrets vault on this Mac.
///
/// Everything goes through the app's `vm.secrets_*` socket methods, which own the
/// Keychain vault and the delivery to machines (end-to-end over each machine's link
/// into its `cmux env receive`). The CLI only collects values (hidden prompt, stdin, a
/// .env file, this shell, `gh auth token`) and prints names, scopes, fingerprints and
/// states. A value is never accepted on the command line, never printed, and never
/// part of an error message.
extension CMUXCLI {
    static let vmSecretsUsage = String(localized: "cloudSecrets.cli.usage", defaultValue: """
        Usage: cmux vm secrets <verb> [options]

        Examples:
          cmux vm secrets set ANTHROPIC_API_KEY      Store a key (the value is read from a hidden prompt)
          cmux vm secrets import .env --dry-run      Preview a .env import; bad lines are skipped
          cmux vm secrets import --gh                Store GitHub CLI's token as GH_TOKEN
          cmux vm secrets status brave-otter         Show what a machine has
          cmux vm secrets sync brave-otter           Send a machine its secrets now

        Verbs:
          ls [--scope <scope>] [--json]              Names, scopes, value IDs, and ages. Never values.
          set NAME… [--scope <scope> | --project | --machine <m>] [--no-sync]
                                                     One value per NAME from a hidden prompt, or one line
                                                     per NAME on stdin. NAME=value is refused: it would
                                                     land in shell history and `ps`.
          import [<.env> | -] [--from-shell [NAME…]] [--gh] [--scope <scope>] [--dry-run] [--no-sync]
                                                     A .env file or stdin, this shell's agent keys, or
                                                     GitHub CLI's token. Lines that are not NAME=value,
                                                     or have an empty value, are skipped and listed.
          rm NAME… [--scope <scope>] [--no-sync]     Remove from this Mac and from synced machines.
          sync <m> [--project <key> | .]             Send a machine its secrets now.
          status <m> [--verify] [--json]             Per name: current, stale, missing, or extra.
          check [<dir>]                              Compare a repository's declared names with the vault.
          link <m> [--project <key> | .]             Give a machine a project's secrets.
          unlink <m> [--project <key> | .]           Stop giving a machine a project's secrets.

        <m> is a machine id or label from `cmux vm ls`.

        Scopes (when a name is stored more than once, the most specific wins):
          all               every Cloud machine (default)
          project[:<key>]   machines linked to a project; the key is host/owner/repo, and a
                            bare `project` or --project means this folder's git remote
          machine:<m>       one machine (same as --machine <m>)

        Secrets live in this Mac's Keychain and travel to a machine only over its end-to-end
        encrypted link, into ~/.config/cmux/env (mode 0600), which every shell cmux starts there
        sources. They never pass through cmux servers. A change syncs to machines that already have
        secrets unless --no-sync or auto-sync is off; new terminals pick up the new values.
        """)

    /// The `vm.secrets_*` budget: a sync of several machines waits on each link.
    static let vmSecretsResponseTimeout: TimeInterval = 620

    // MARK: - Dispatch

    func runVMSecretsCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        if rest.contains("--help") || rest.contains("-h") {
            print(Self.vmSecretsUsage)
            return
        }
        let json = jsonOutput || rest.contains("--json")
        // `cmux vm secrets` and `cmux vm secrets --scope …` list.
        let explicitVerb = rest.first.flatMap { $0.hasPrefix("-") ? nil : $0.lowercased() }
        let verb = explicitVerb ?? "ls"
        let tail = (explicitVerb == nil ? rest : Array(rest.dropFirst())).filter { $0 != "--json" }
        switch verb {
        case "ls", "list":
            try runVMSecretsList(tail, client: client, json: json)
        case "set", "add":
            try runVMSecretsSet(tail, client: client, json: json)
        case "import":
            try runVMSecretsImport(tail, client: client, json: json)
        case "rm", "remove", "unset", "delete":
            try runVMSecretsRemove(tail, client: client, json: json)
        case "sync", "push":
            try runVMSecretsSync(tail, client: client, json: json)
        case "status":
            try runVMSecretsStatus(tail, client: client, json: json)
        case "check":
            try runVMSecretsCheck(tail, client: client, json: json)
        case "link", "unlink":
            try runVMSecretsLink(tail, linking: verb == "link", client: client, json: json)
        case "help":
            print(Self.vmSecretsUsage)
        default:
            throw CLIError(message: String(format: String(localized: "cloudSecrets.cli.unknownVerb", defaultValue: "vm secrets: unknown verb '%1$@'\n\n%2$@"), verb, Self.vmSecretsUsage))
        }
    }

    // MARK: - Verbs

    private func runVMSecretsList(_ args: [String], client: SocketClient, json: Bool) throws {
        let options = try Self.parseVMSecretsOptions(args, verb: "ls", valueFlags: ["--scope", "--machine"], boolFlags: ["--project"])
        guard options.positional.isEmpty else {
            throw CLIError(message: Self.vmSecretsUsage, exitCode: 2)
        }
        var params: [String: Any] = [:]
        if let spec = try Self.vmSecretsScopeSpec(options) {
            let resolved = try resolveVMSecretsMachineScope(spec, client: client)
            params.merge(vmSecretsScopeParams(resolved, directory: FileManager.default.currentDirectoryPath)) { _, new in new }
        }
        let response = try client.sendV2(method: "vm.secrets_list", params: params, responseTimeout: 60)
        if json {
            print(jsonString(response))
            return
        }
        let secrets = (response["secrets"] as? [[String: Any]]) ?? []
        if secrets.isEmpty {
            print(String(localized: "cloudSecrets.cli.ls.empty", defaultValue: "No Cloud Secrets yet. Add one with: cmux vm secrets set ANTHROPIC_API_KEY"))
            return
        }
        print(Self.vmSecretsTable(secrets, now: Date()))
        let machines = (response["machines"] as? [[String: Any]]) ?? []
        let failing = machines.filter { ($0["last_error"] as? String) != nil }
        if !failing.isEmpty {
            print("")
            for machine in failing {
                let id = (machine["id"] as? String) ?? "?"
                let error = (machine["last_error"] as? String) ?? ""
                print(String(format: String(localized: "cloudSecrets.cli.ls.machineError", defaultValue: "%1$@: last sync failed: %2$@"), id, error))
            }
        }
    }

    private func runVMSecretsSet(_ args: [String], client: SocketClient, json: Bool) throws {
        let options = try Self.parseVMSecretsOptions(args, verb: "set", valueFlags: ["--scope", "--machine"], boolFlags: ["--project", "--no-sync"])
        let names = try Self.vmSecretsNames(options.positional, verb: "set")
        let spec = try resolveVMSecretsMachineScope(Self.vmSecretsScopeSpec(options) ?? .all, client: client)
        let values: [String]
        if isatty(STDIN_FILENO) == 1 {
            values = try names.map { name in
                try Self.readVMSecretHidden(prompt: String(format: String(localized: "cloudSecrets.cli.set.prompt", defaultValue: "Value for %@ (input hidden): "), name))
            }
        } else {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else {
                throw CLIError(message: String(localized: "cloudSecrets.cli.stdinNotUTF8", defaultValue: "vm secrets: stdin is not UTF-8 text"), exitCode: 2)
            }
            values = try Self.vmSecretsValuesFromStdin(text, names: names)
        }
        let entries = zip(names, values).map { VMEnvAssignment(key: $0.0, value: $0.1) }
        try sendVMSecretsSet(
            entries: entries,
            spec: spec,
            source: "manual",
            sync: options.flags.contains("--no-sync") ? false : nil,
            dryRun: false,
            skipped: [],
            client: client,
            json: json
        )
    }

    private func runVMSecretsImport(_ args: [String], client: SocketClient, json: Bool) throws {
        let request = try Self.parseVMSecretsImport(args)
        let spec = try resolveVMSecretsMachineScope(Self.vmSecretsScopeSpec(request.options) ?? .all, client: client)
        var entries: [VMEnvAssignment] = []
        var skipped: [VMSecretsDotenvSkip] = []
        var sources: [String] = []
        if let file = request.file {
            let text: String
            if file == "-" {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                guard let decoded = String(data: data, encoding: .utf8) else {
                    throw CLIError(message: String(localized: "cloudSecrets.cli.stdinNotUTF8", defaultValue: "vm secrets: stdin is not UTF-8 text"), exitCode: 2)
                }
                text = decoded
                sources.append("dotenv:stdin")
            } else {
                let path = resolvePath(file)
                guard let data = FileManager.default.contents(atPath: path), let decoded = String(data: data, encoding: .utf8) else {
                    throw CLIError(message: String(format: String(localized: "cloudSecrets.cli.import.cannotRead", defaultValue: "vm secrets import: cannot read %@"), path), exitCode: 2)
                }
                text = decoded
                sources.append("dotenv:" + (path as NSString).lastPathComponent)
            }
            // Lenient: a bad line or an empty value is reported and skipped; the
            // rest of the file still imports.
            let parsed = Self.parseVMSecretsDotenv(text)
            entries += parsed.entries
            skipped = parsed.skipped
        }
        if request.fromShell {
            var shellNames = request.shellNames
            if shellNames.isEmpty {
                let listed = try client.sendV2(method: "vm.secrets_list", params: [:], responseTimeout: 60)
                shellNames = (listed["well_known"] as? [String]) ?? []
            }
            let picked = Self.vmSecretsShellEntries(names: shellNames, environment: ProcessInfo.processInfo.environment, explicit: !request.shellNames.isEmpty)
            if let missing = picked.missing.first {
                throw CLIError(message: String(format: String(localized: "cloudSecrets.cli.import.shellMissing", defaultValue: "vm secrets import: %@ is not set in this shell"), missing), exitCode: 2)
            }
            entries += picked.entries
            sources.append("shell")
        }
        if request.gh {
            let token = try Self.readGitHubCLIToken()
            entries.append(VMEnvAssignment(key: "GH_TOKEN", value: token))
            sources.append("gh")
        }
        guard !entries.isEmpty else {
            if !skipped.isEmpty {
                for line in Self.vmSecretsSkipLines(skipped) {
                    cliWriteStderr(line + "\n")
                }
                throw CLIError(message: String(
                    format: String(localized: "cloudSecrets.cli.import.allSkipped", defaultValue: "vm secrets import: nothing to import. Every line was skipped: %@"),
                    Self.vmSecretsSkipSummaryItems(skipped)
                ))
            }
            if request.fromShell && request.file == nil && !request.gh {
                print(String(localized: "cloudSecrets.cli.import.shellNone", defaultValue: "No well-known agent keys are set in this shell. Name them: cmux vm secrets import --from-shell NAME"))
                return
            }
            throw CLIError(message: String(format: String(localized: "cloudSecrets.cli.import.nothing", defaultValue: "vm secrets import: give a .env file, - for stdin, --from-shell, or --gh\n\n%@"), Self.vmSecretsUsage), exitCode: 2)
        }
        try sendVMSecretsSet(
            entries: Self.mergedVMEnvAssignments(entries),
            spec: spec,
            source: sources.count == 1 ? sources[0] : "manual",
            sync: request.options.flags.contains("--no-sync") ? false : nil,
            dryRun: request.dryRun,
            skipped: skipped,
            client: client,
            json: json
        )
    }

    private func runVMSecretsRemove(_ args: [String], client: SocketClient, json: Bool) throws {
        let options = try Self.parseVMSecretsOptions(args, verb: "rm", valueFlags: ["--scope", "--machine"], boolFlags: ["--project", "--no-sync"])
        let names = try Self.vmSecretsNames(options.positional, verb: "rm")
        // The message names the scope as typed (a machine by its label, not its id).
        let typedSpec = try Self.vmSecretsScopeSpec(options) ?? .all
        let spec = try resolveVMSecretsMachineScope(typedSpec, client: client)
        var params = vmSecretsScopeParams(spec, directory: FileManager.default.currentDirectoryPath)
        params["names"] = names
        if options.flags.contains("--no-sync") { params["sync"] = false }
        let response = try client.sendV2(method: "vm.secrets_rm", params: params, responseTimeout: Self.vmSecretsResponseTimeout)
        let changes = (response["changes"] as? [[String: Any]]) ?? []
        let removed = changes.compactMap { $0["name"] as? String }
        let notStored = names.filter { !removed.contains($0) }
        if json {
            print(jsonString(response))
        } else {
            if !removed.isEmpty {
                print(String(format: String(localized: "cloudSecrets.cli.rm.done", defaultValue: "OK removed %@"), removed.joined(separator: ", ")))
            }
            printVMSecretsSyncLines((response["synced"] as? [[String: Any]]) ?? [], changes: changes, client: client)
        }
        // A name that was not stored is a mistake worth a non-zero exit (a typo, or the
        // wrong scope), even when other names were removed.
        if !notStored.isEmpty {
            throw CLIError(message: String(
                format: String(localized: "cloudSecrets.cli.rm.notStored", defaultValue: "No secret named %1$@ for %2$@."),
                notStored.joined(separator: ", "),
                Self.vmSecretsScopePhrase(typedSpec)
            ))
        }
    }

    private func runVMSecretsSync(_ args: [String], client: SocketClient, json: Bool) throws {
        let options = try Self.parseVMSecretsOptions(args, verb: "sync", valueFlags: ["--project"], boolFlags: [])
        guard options.positional.count == 1, let selector = options.positional.first else {
            throw CLIError(message: Self.vmSecretsUsage, exitCode: 2)
        }
        let machine = try resolveVMSecretsMachine(selector, client: client)
        var params: [String: Any] = ["id": machine.id]
        if let project = options.values["--project"] {
            params.merge(vmSecretsProjectParams(project, directory: FileManager.default.currentDirectoryPath)) { _, new in new }
        }
        let before = json ? nil : vmSecretsStatusRowsBeforeSync(machine.id, client: client)
        let response = try client.sendV2(method: "vm.secrets_sync", params: params, responseTimeout: 260)
        if json {
            print(jsonString(response))
        } else if (response["error"] as? String)?.isEmpty ?? true {
            let changes = Self.vmSecretsSyncChanges(result: response, before: before)
            for line in Self.vmSecretsSyncReport(machine: machine.display, changes: changes, noop: (response["noop"] as? Bool) == true) {
                print(line)
            }
        }
        if let error = response["error"] as? String, !error.isEmpty {
            throw CLIError(message: String(format: String(localized: "cloudSecrets.cli.sync.failed", defaultValue: "vm secrets sync: %@"), error))
        }
    }

    private func runVMSecretsStatus(_ args: [String], client: SocketClient, json: Bool) throws {
        let options = try Self.parseVMSecretsOptions(args, verb: "status", valueFlags: [], boolFlags: ["--verify"])
        guard options.positional.count == 1, let selector = options.positional.first else {
            throw CLIError(message: Self.vmSecretsUsage, exitCode: 2)
        }
        let machine = try resolveVMSecretsMachine(selector, client: client)
        let response = try client.sendV2(
            method: "vm.secrets_status",
            params: ["id": machine.id, "verify": options.flags.contains("--verify")],
            responseTimeout: 120
        )
        if json {
            print(jsonString(response))
            return
        }
        let rows = (response["rows"] as? [[String: Any]]) ?? []
        if rows.isEmpty {
            print(String(format: String(localized: "cloudSecrets.cli.status.empty", defaultValue: "No Cloud Secrets apply to %@."), machine.display))
        } else {
            print(Self.vmSecretsStatusTable(rows))
        }
        if let error = response["last_error"] as? String, !error.isEmpty {
            print(String(format: String(localized: "cloudSecrets.cli.status.lastError", defaultValue: "Last sync failed: %@"), error))
        }
    }

    private func runVMSecretsCheck(_ args: [String], client: SocketClient, json: Bool) throws {
        let options = try Self.parseVMSecretsOptions(args, verb: "check", valueFlags: [], boolFlags: [])
        guard options.positional.count <= 1 else { throw CLIError(message: Self.vmSecretsUsage, exitCode: 2) }
        let directory = resolvePath(options.positional.first ?? FileManager.default.currentDirectoryPath)
        let response = try client.sendV2(method: "vm.secrets_check", params: ["dir": directory], responseTimeout: 60)
        if json {
            print(jsonString(response))
            return
        }
        let declared = (response["declared"] as? [[String: Any]]) ?? []
        if declared.isEmpty {
            print(String(localized: "cloudSecrets.cli.check.none", defaultValue: "This project declares no secrets (.cmux/cloud.json `env`, or devcontainer `secrets`)."))
            return
        }
        var missing: [String] = []
        for item in declared {
            let name = (item["name"] as? String) ?? "?"
            let scopes = (item["scopes"] as? [String]) ?? []
            if scopes.isEmpty {
                missing.append(name)
                print(String(format: String(localized: "cloudSecrets.cli.check.missing", defaultValue: "missing  %@"), name))
            } else {
                print(String(format: String(localized: "cloudSecrets.cli.check.stored", defaultValue: "ok       %1$@ (%2$@)"), name, scopes.joined(separator: ", ")))
            }
        }
        if !missing.isEmpty {
            print("")
            print(String(format: String(localized: "cloudSecrets.cli.check.hint", defaultValue: "Add the missing ones with: cmux vm secrets set %@"), missing.joined(separator: " ")))
            throw CLIError(message: String(format: String(localized: "cloudSecrets.cli.check.failed", defaultValue: "%ld declared secrets are missing"), missing.count))
        }
    }

    private func runVMSecretsLink(_ args: [String], linking: Bool, client: SocketClient, json: Bool) throws {
        let verb = linking ? "link" : "unlink"
        let options = try Self.parseVMSecretsOptions(args, verb: verb, valueFlags: ["--project"], boolFlags: ["--no-sync"])
        guard options.positional.count == 1, let selector = options.positional.first else {
            throw CLIError(message: Self.vmSecretsUsage, exitCode: 2)
        }
        let machine = try resolveVMSecretsMachine(selector, client: client)
        var params: [String: Any] = ["id": machine.id]
        params.merge(vmSecretsProjectParams(options.values["--project"] ?? ".", directory: FileManager.default.currentDirectoryPath)) { _, new in new }
        guard params["project"] != nil || params["project_remote_url"] != nil || params["project_dir_name"] != nil else {
            throw CLIError(message: Self.vmSecretsUsage, exitCode: 2)
        }
        if options.flags.contains("--no-sync") { params["sync"] = false }
        let before = json || options.flags.contains("--no-sync") ? nil : vmSecretsStatusRowsBeforeSync(machine.id, client: client)
        let response = try client.sendV2(method: "vm.secrets_\(verb)", params: params, responseTimeout: 260)
        if json {
            print(jsonString(response))
            return
        }
        let project = (response["project"] as? String) ?? "?"
        let format = linking
            ? String(localized: "cloudSecrets.cli.link.done", defaultValue: "OK linked %1$@ to %2$@")
            : String(localized: "cloudSecrets.cli.unlink.done", defaultValue: "OK unlinked %1$@ from %2$@")
        print(String(format: format, machine.display, project))
        if let sync = response["sync"] as? [String: Any], (sync["error"] as? String)?.isEmpty ?? true {
            // Linking adds the project's names; unlinking removes them.
            let changes = Self.vmSecretsSyncChanges(result: sync, before: before)
            for line in Self.vmSecretsSyncReport(machine: machine.display, changes: changes, noop: (sync["noop"] as? Bool) == true) {
                print(line)
            }
        } else if let sync = response["sync"] as? [String: Any], let error = sync["error"] as? String {
            print(String(format: String(localized: "cloudSecrets.cli.sync.machineFailed", defaultValue: "%1$@: sync failed: %2$@"), machine.display, error))
        }
    }

    // MARK: - `vm agent` hook

    /// How long `vm agent` waits on the app for each pre-launch Cloud Secrets request
    /// (the sync and the missing-secret check). Both are best-effort, so a hung app
    /// delays the agent by at most this much per request, never minutes.
    static let vmAgentSecretsPreLaunchTimeout: TimeInterval = 30

    /// Brings the agent's machine up to date before the agent starts, linking it to the
    /// working directory's project when it has a git remote. Never fatal: a failure is
    /// one stderr line and the agent starts anyway.
    func syncVMSecretsBeforeAgent(machine: String, workDirectory: String, client: SocketClient) {
        var params: [String: Any] = ["id": machine]
        if let remote = Self.vmSecretsGitRemoteURL(directory: workDirectory) {
            params["project_remote_url"] = remote
        }
        do {
            let response = try client.sendV2(method: "vm.secrets_sync", params: params, responseTimeout: Self.vmAgentSecretsPreLaunchTimeout)
            if let error = response["error"] as? String, !error.isEmpty {
                cliWriteStderr(Self.vmSecretsAgentWarning(error) + "\n")
            }
        } catch let error as CLIError where error.v2Code == "method_not_found" {
            // An app without Cloud Secrets: nothing to deliver.
        } catch let error as CLIError {
            cliWriteStderr(Self.vmSecretsAgentWarning(error.message) + "\n")
        } catch {
            cliWriteStderr(Self.vmSecretsAgentWarning(String(describing: type(of: error))) + "\n")
        }
    }

    // MARK: - Missing-secret preflight

    /// A declared name the target machine's effective set does not have.
    struct VMSecretsPreflightGap: Equatable {
        let name: String
        let description: String?
        /// The declaring file, relative to the repository root.
        let source: String
    }

    /// What `vm.secrets_check` said about one repository and machine.
    struct VMSecretsPreflight: Equatable {
        /// The normalized project key the check used, when one resolved.
        let projectKey: String?
        let missing: [VMSecretsPreflightGap]
    }

    /// Compares the names a repository declares (`.cmux/cloud.json` `env`, devcontainer
    /// `secrets`) with the secrets that reach `machine` (all machines, its linked projects,
    /// `project`, and the machine itself) and returns warning lines to print before setup
    /// or an agent starts. Empty when nothing is missing or the check is unavailable; it
    /// never throws and never blocks, because a missing key is the user's call.
    ///
    /// - `project`: a project key or git remote URL. nil with a `directory` uses that
    ///   directory's origin remote.
    /// - `directory`: a checkout on this Mac; the app reads its declaring files.
    /// - `manifestFiles`: the declaring files' text from a checkout elsewhere (keys such as
    ///   `.cmux/cloud.json`); wins over `directory`. These files hold names, never values.
    ///
    /// The add hint says `--project` when `directory` is the current directory (the
    /// form `cmux vm secrets set` resolves the same way), otherwise
    /// `--scope project:<key>`.
    func vmSecretsPreflightWarnings(
        machine: String,
        project: String?,
        directory: String?,
        manifestFiles: [String: String] = [:],
        client: SocketClient
    ) -> [String] {
        guard let preflight = vmSecretsPreflight(
            machine: machine,
            project: project,
            directory: directory,
            manifestFiles: manifestFiles,
            client: client
        ) else { return [] }
        let usesCurrentDirectory = project == nil && directory.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
                == URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path
        } == true
        return Self.vmSecretsPreflightLines(preflight, hintUsesCurrentDirectory: usesCurrentDirectory)
    }

    /// The structured form of ``vmSecretsPreflightWarnings(machine:project:directory:manifestFiles:client:)``;
    /// nil when there is nothing to check or the app cannot check it.
    func vmSecretsPreflight(
        machine: String,
        project: String?,
        directory: String?,
        manifestFiles: [String: String],
        client: SocketClient
    ) -> VMSecretsPreflight? {
        var params: [String: Any] = ["id": machine]
        if !manifestFiles.isEmpty {
            params["files"] = manifestFiles
        } else if let directory {
            params["dir"] = directory
        } else {
            return nil
        }
        if let project, !project.isEmpty {
            params["project"] = project
        } else if let directory, let remote = Self.vmSecretsGitRemoteURL(directory: directory) {
            params["project_remote_url"] = remote
        }
        guard let response = try? client.sendV2(method: "vm.secrets_check", params: params, responseTimeout: Self.vmAgentSecretsPreLaunchTimeout) else {
            // An app without the check (or without `files`): no warning rather than a wrong one.
            return nil
        }
        return Self.vmSecretsPreflight(fromCheck: response)
    }

    /// Parses a `vm.secrets_check` response. An app that predates `missing` reports
    /// declared names stored in no scope at all.
    static func vmSecretsPreflight(fromCheck response: [String: Any]) -> VMSecretsPreflight {
        let declared = (response["declared"] as? [[String: Any]]) ?? []
        let missingNames: Set<String>
        if let names = response["missing"] as? [String] {
            missingNames = Set(names)
        } else {
            missingNames = Set(declared.filter { ($0["stored"] as? Bool) == false }.compactMap { $0["name"] as? String })
        }
        let gaps = declared.compactMap { item -> VMSecretsPreflightGap? in
            guard let name = item["name"] as? String, missingNames.contains(name), isValidVMEnvKey(name) else { return nil }
            let source = (item["source"] as? String).map { vmSecretsPrintable($0, limit: 80) } ?? ".cmux/cloud.json"
            let description = (item["description"] as? String).map { vmSecretsPrintable($0, limit: 80) }
            return VMSecretsPreflightGap(name: name, description: description?.isEmpty == true ? nil : description, source: source)
        }
        return VMSecretsPreflight(projectKey: response["project"] as? String, missing: gaps)
    }

    /// `Missing secrets for owner/repo: NAME (from file — "description"), …` and the
    /// command that adds them. Empty when nothing is missing.
    static func vmSecretsPreflightLines(_ preflight: VMSecretsPreflight, hintUsesCurrentDirectory: Bool) -> [String] {
        guard !preflight.missing.isEmpty else { return [] }
        let items = preflight.missing.map { gap -> String in
            if let description = gap.description {
                return String(
                    format: String(localized: "cloudSecrets.cli.preflight.itemDescribed", defaultValue: "%1$@ (from %2$@ \u{2014} \"%3$@\")"),
                    gap.name, gap.source, description
                )
            }
            return String(
                format: String(localized: "cloudSecrets.cli.preflight.item", defaultValue: "%1$@ (from %2$@)"),
                gap.name, gap.source
            )
        }
        let label = preflight.projectKey.map(vmSecretsShortProjectLabel)
            ?? String(localized: "cloudSecrets.cli.preflight.thisProject", defaultValue: "this project")
        let names = preflight.missing.map(\.name).joined(separator: " ")
        let scope: String
        if hintUsesCurrentDirectory || preflight.projectKey == nil {
            scope = "--project"
        } else {
            scope = "--scope project:\(preflight.projectKey ?? "")"
        }
        return [
            String(
                format: String(localized: "cloudSecrets.cli.preflight.missing", defaultValue: "Missing secrets for %1$@: %2$@."),
                label, items.joined(separator: ", ")
            ),
            String(
                format: String(localized: "cloudSecrets.cli.preflight.add", defaultValue: "Add: cmux vm secrets set %1$@ %2$@ (continuing without them)"),
                names, scope
            ),
        ]
    }

    /// "owner/repo" for `github.com/owner/repo`, the folder for `local/<name>`.
    static func vmSecretsShortProjectLabel(_ key: String) -> String {
        let parts = key.split(separator: "/").map(String.init)
        if parts.first == "local", parts.count >= 2 { return parts.dropFirst().joined(separator: "/") }
        guard parts.count >= 3 else { return key }
        return parts.suffix(2).joined(separator: "/")
    }

    /// Repository text made safe for a terminal line: control characters (escape
    /// sequences included) become spaces, and it is cut at `limit` characters.
    static func vmSecretsPrintable(_ text: String, limit: Int) -> String {
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : scalar
        })).trimmingCharacters(in: .whitespaces)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(max(0, limit - 1))) + "\u{2026}"
    }

    static func vmSecretsAgentWarning(_ reason: String) -> String {
        String(format: String(localized: "cloudSecrets.cli.agent.syncWarning", defaultValue: "[cmux vm agent] warning: Cloud Secrets were not synced (%@); starting the agent anyway."), reason)
    }

    // MARK: - Shared request plumbing

    private func sendVMSecretsSet(
        entries: [VMEnvAssignment],
        spec: VMSecretsScopeSpec,
        source: String,
        sync: Bool?,
        dryRun: Bool,
        skipped: [VMSecretsDotenvSkip],
        client: SocketClient,
        json: Bool
    ) throws {
        var params = vmSecretsScopeParams(spec, directory: FileManager.default.currentDirectoryPath)
        // Values cross only the authenticated local socket; the app answers with names.
        params["entries"] = entries.map { ["key": $0.key, "value": $0.value] }
        params["source"] = source
        if let sync { params["sync"] = sync }
        if dryRun { params["dry_run"] = true }
        var response = try client.sendV2(method: "vm.secrets_set", params: params, responseTimeout: Self.vmSecretsResponseTimeout)
        if json {
            if !skipped.isEmpty {
                // Line numbers and reasons only; a skipped line's text is never echoed.
                response["skipped"] = skipped.map { skip -> [String: Any] in
                    var item: [String: Any] = ["line": skip.line, "reason": skip.code]
                    if let name = skip.name { item["name"] = name }
                    return item
                }
            }
            print(jsonString(response))
            return
        }
        let changes = (response["changes"] as? [[String: Any]]) ?? []
        for line in Self.vmSecretsChangeLines(changes, dryRun: dryRun) {
            print(line)
        }
        for line in Self.vmSecretsSkipLines(skipped) {
            print(line)
        }
        if !skipped.isEmpty {
            print(Self.vmSecretsImportSummary(imported: entries.count, skipped: skipped, dryRun: dryRun))
        }
        printVMSecretsSyncLines((response["synced"] as? [[String: Any]]) ?? [], changes: changes, client: client)
    }

    /// One line per machine a vault change reached, naming only what changed there
    /// ("Synced 1 change to brave-otter: OPENAI_API_KEY updated"), then the reminder
    /// that open shells keep their old values. A machine with nothing new prints nothing.
    private func printVMSecretsSyncLines(_ results: [[String: Any]], changes: [[String: Any]], client: SocketClient) {
        guard !results.isEmpty else { return }
        let labels = vmSecretsMachineLabels(client: client)
        var deliveredSomething = false
        for result in results {
            let id = (result["machine"] as? String) ?? "?"
            let machine = labels[id] ?? id
            if let error = result["error"] as? String, !error.isEmpty {
                print(String(format: String(localized: "cloudSecrets.cli.sync.machineFailed", defaultValue: "%1$@: sync failed: %2$@"), machine, error))
                continue
            }
            guard (result["noop"] as? Bool) != true else { continue }
            let reached = Set(((result["sent"] as? [String]) ?? []) + ((result["removed"] as? [String]) ?? []))
            let applied = changes.compactMap { change -> VMSecretsSyncChange? in
                guard let name = change["name"] as? String, reached.contains(name),
                      let kind = change["kind"] as? String, kind != "unchanged" else { return nil }
                return VMSecretsSyncChange(name: name, kind: kind)
            }
            guard !applied.isEmpty else { continue }
            deliveredSomething = true
            print(Self.vmSecretsSyncedLine(machine: machine, changes: applied))
        }
        if deliveredSomething {
            print(String(localized: "cloudSecrets.cli.sync.newTerminals", defaultValue: "Open a new terminal on the machine to use the updated values."))
        }
    }

    /// The machine's status rows before a sync, so the report names only what changed.
    /// nil when status cannot be read (an older app, or no link); the report then lists
    /// the delivered names.
    private func vmSecretsStatusRowsBeforeSync(_ machine: String, client: SocketClient) -> [[String: Any]]? {
        guard let response = try? client.sendV2(
            method: "vm.secrets_status",
            params: ["id": machine, "verify": false],
            responseTimeout: 120
        ) else { return nil }
        return response["rows"] as? [[String: Any]]
    }

    // MARK: - Machines by id or label

    /// A machine argument resolved against `vm.list`: the id to send, and the label to print.
    struct VMSecretsMachine: Equatable {
        let id: String
        let label: String?

        var display: String { label ?? id }
    }

    /// `secrets status|sync|link|unlink <machine>`: an id or a label (`vm ls` NAME or
    /// LABEL), through the same resolver every `cmux vm` verb uses. An unknown machine
    /// is an error, never "every secret missing". When the machine list cannot be read
    /// (an app without `vm.list`), the argument goes to the app as typed.
    func resolveVMSecretsMachine(_ selector: String, client: SocketClient) throws -> VMSecretsMachine {
        guard let listed = try? client.sendV2(method: "vm.list", responseTimeout: 60),
              let vms = listed["vms"] as? [[String: Any]] else {
            return VMSecretsMachine(id: selector, label: nil)
        }
        func label(of id: String) -> String? {
            guard let vm = vms.first(where: { ($0["id"] as? String) == id }) else { return nil }
            return [vm["displayName"], vm["slug"]].compactMap { $0 as? String }.first { !$0.isEmpty }
        }
        switch VMMachineSelectorResolver().resolve(selector, vms: vms) {
        case .id(let id), .label(id: let id):
            return VMSecretsMachine(id: id, label: label(of: id))
        case .ambiguous(let matches):
            let list = matches.map { "  \($0.id)  \($0.label)" }.joined(separator: "\n")
            throw CLIError(message: String(
                format: String(localized: "cli.vm.machineLabel.ambiguous", defaultValue: "%1$@ is the label of more than one machine; use an id:\n%2$@"),
                selector, list
            ))
        case .unknown:
            throw CLIError(message: String(
                format: String(localized: "cloudSecrets.cli.unknownMachine", defaultValue: "vm secrets: no machine named %@. Run `cmux vm ls` to see your machines."),
                selector
            ))
        }
    }

    /// `--machine <label>` (or `--scope machine:<label>`) stores under the machine's id.
    /// A name no machine has passes through unchanged, so a secret left behind by a
    /// deleted machine can still be listed and removed.
    func resolveVMSecretsMachineScope(_ spec: VMSecretsScopeSpec, client: SocketClient) throws -> VMSecretsScopeSpec {
        guard case .machine(let selector) = spec else { return spec }
        guard let listed = try? client.sendV2(method: "vm.list", responseTimeout: 60),
              let vms = listed["vms"] as? [[String: Any]] else { return spec }
        switch VMMachineSelectorResolver().resolve(selector, vms: vms) {
        case .id(let id), .label(id: let id):
            return .machine(id)
        case .ambiguous(let matches):
            let list = matches.map { "  \($0.id)  \($0.label)" }.joined(separator: "\n")
            throw CLIError(message: String(
                format: String(localized: "cli.vm.machineLabel.ambiguous", defaultValue: "%1$@ is the label of more than one machine; use an id:\n%2$@"),
                selector, list
            ))
        case .unknown:
            // Kept as typed so a secret left by a deleted machine can still be listed
            // and removed, but a typo must not pass silently.
            cliWriteStderr(String(
                format: String(
                    localized: "cloudSecrets.cli.scope.unknownMachine",
                    defaultValue: "Warning: no machine is named %@ (see `cmux vm ls`); using it as typed, so a secret stored for it reaches no machine until one has that id."
                ),
                selector
            ) + "\n")
            return spec
        }
    }

    /// Machine id → label, for printing. Empty when the list cannot be read.
    private func vmSecretsMachineLabels(client: SocketClient) -> [String: String] {
        guard let listed = try? client.sendV2(method: "vm.list", responseTimeout: 60),
              let vms = listed["vms"] as? [[String: Any]] else { return [:] }
        var labels: [String: String] = [:]
        for vm in vms {
            guard let id = vm["id"] as? String,
                  let label = [vm["displayName"], vm["slug"]].compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) else { continue }
            labels[id] = label
        }
        return labels
    }

    /// Socket params for a scope, resolving "this project" from `directory`'s git remote.
    func vmSecretsScopeParams(_ spec: VMSecretsScopeSpec, directory: String) -> [String: Any] {
        switch spec {
        case .all:
            return ["scope": "all"]
        case .machine(let id):
            return ["scope": "machine:\(id)"]
        case .project(let key?):
            return ["scope": "project:\(key)"]
        case .project(nil):
            var params: [String: Any] = ["scope": "project"]
            params.merge(vmSecretsProjectParams(".", directory: directory)) { _, new in new }
            return params
        }
    }

    /// `project` for an explicit key, or the directory's remote URL and name for `.`.
    func vmSecretsProjectParams(_ project: String, directory: String) -> [String: Any] {
        if project != "." { return ["project": project] }
        var params: [String: Any] = [:]
        if let remote = Self.vmSecretsGitRemoteURL(directory: directory) {
            params["project_remote_url"] = remote
        }
        let top = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", directory, "rev-parse", "--show-toplevel"],
            timeout: 10
        )
        let root = top.status == 0 ? top.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        params["project_dir_name"] = ((root.isEmpty ? directory : root) as NSString).lastPathComponent
        return params
    }

    /// `git config --get remote.origin.url` in `directory`, run without a shell.
    static func vmSecretsGitRemoteURL(directory: String) -> String? {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", directory, "config", "--get", "remote.origin.url"],
            timeout: 10
        )
        guard result.status == 0, !result.timedOut else { return nil }
        let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    /// `gh auth token`, captured through a pipe; the token is never echoed.
    static func readGitHubCLIToken() throws -> String {
        let result = CLIProcessRunner.runProcess(executablePath: "/usr/bin/env", arguments: ["gh", "auth", "token"], timeout: 30)
        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !result.timedOut, !token.isEmpty, !token.contains("\n") else {
            throw CLIError(message: String(localized: "cloudSecrets.cli.import.ghFailed", defaultValue: "vm secrets import --gh: `gh auth token` did not return a token. Install the GitHub CLI and run `gh auth login`, then retry."))
        }
        return token
    }

    // MARK: - Hidden prompt

    /// Reads one line from the terminal with echo off. Echo is restored on return and,
    /// through signal handlers, on Ctrl-C, Ctrl-\\ or termination while the prompt is
    /// open; Ctrl-Z restores it while stopped and hides input again on resume.
    /// Canonical mode is off too, so a value longer than the terminal's line buffer
    /// (MAX_CANON, 1024 bytes on macOS) is read whole, up to the newline.
    static func readVMSecretHidden(prompt: String) throws -> String {
        cliWriteStderr(prompt)
        var original = termios()
        let hasTerminal = tcgetattr(STDIN_FILENO, &original) == 0
        guard hasTerminal else {
            guard let line = readLine(strippingNewline: true) else {
                throw CLIError(message: String(localized: "cloudSecrets.cli.set.noInput", defaultValue: "vm secrets set: no value entered"), exitCode: 2)
            }
            return try vmSecretsEnteredValue(line)
        }
        var hidden = original
        hidden.c_lflag &= ~tcflag_t(ECHO | ICANON)
        // One byte at a time, blocking: the line is assembled here, not by the tty.
        withUnsafeMutableBytes(of: &hidden.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        vmSecretsSavedTermios = original
        vmSecretsHiddenTermios = hidden
        let handled: [Int32] = [SIGINT, SIGTERM, SIGQUIT, SIGHUP]
        var previous: [Int32: (@convention(c) (Int32) -> Void)?] = [:]
        for signalNumber in handled {
            previous[signalNumber] = signal(signalNumber, vmSecretsRestoreTerminalAndExit)
        }
        let previousStop = signal(SIGTSTP, vmSecretsSuspendWithTerminalRestored)
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden)
        defer {
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &original)
            for signalNumber in handled {
                signal(signalNumber, previous[signalNumber] ?? SIG_DFL)
            }
            signal(SIGTSTP, previousStop ?? SIG_DFL)
            vmSecretsSavedTermios = nil
            vmSecretsHiddenTermios = nil
            cliWriteStderr("\n")
        }
        var bytes: [UInt8] = []
        var sawInput = false
        while true {
            var byte: UInt8 = 0
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { break }
            sawInput = true
            switch byte {
            case 0x0A, 0x0D:
                return try vmSecretsEnteredValue(String(decoding: bytes, as: UTF8.self))
            case 0x04 where bytes.isEmpty:
                // Ctrl-D on an empty line: no value.
                throw CLIError(message: String(localized: "cloudSecrets.cli.set.noInput", defaultValue: "vm secrets set: no value entered"), exitCode: 2)
            case 0x04:
                // Ctrl-D after input ends the value, as in canonical mode.
                return try vmSecretsEnteredValue(String(decoding: bytes, as: UTF8.self))
            case 0x7F, 0x08:
                // Backspace removes one whole UTF-8 character.
                while let last = bytes.popLast(), last & 0xC0 == 0x80 {}
            case 0x15:
                bytes.removeAll()
            case 0x00..<0x20:
                // Other control bytes are never part of a pasted key.
                continue
            default:
                bytes.append(byte)
            }
        }
        // End of input without a newline: whatever was typed is the value.
        guard sawInput, !bytes.isEmpty else {
            throw CLIError(message: String(localized: "cloudSecrets.cli.set.noInput", defaultValue: "vm secrets set: no value entered"), exitCode: 2)
        }
        return try vmSecretsEnteredValue(String(decoding: bytes, as: UTF8.self))
    }

    /// A typed value without its line ending; blank input is no value.
    private static func vmSecretsEnteredValue(_ line: String) throws -> String {
        let value = line.hasSuffix("\r") ? String(line.dropLast()) : line
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw CLIError(message: String(localized: "cloudSecrets.cli.set.noInput", defaultValue: "vm secrets set: no value entered"), exitCode: 2)
        }
        return value
    }

    // MARK: - Pure helpers (no socket; shared by the verbs above and the tests)

    enum VMSecretsScopeSpec: Equatable {
        case all
        /// nil: the current directory's project.
        case project(String?)
        case machine(String)
    }

    struct VMSecretsOptions: Equatable {
        var positional: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []
    }

    struct VMSecretsImportRequest: Equatable {
        var options = VMSecretsOptions()
        var file: String?
        var fromShell = false
        var shellNames: [String] = []
        var gh = false
        var dryRun = false
    }

    /// Splits `args` into positionals, `--flag value` / `--flag=value` options, and
    /// boolean flags. `--project=<key>` is accepted wherever `--project` is a bool.
    static func parseVMSecretsOptions(
        _ args: [String],
        verb: String,
        valueFlags: Set<String>,
        boolFlags: Set<String>
    ) throws -> VMSecretsOptions {
        var options = VMSecretsOptions()
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("--"), let equals = arg.firstIndex(of: "=") {
                let flag = String(arg[..<equals])
                let value = String(arg[arg.index(after: equals)...])
                guard valueFlags.contains(flag) || boolFlags.contains(flag) else {
                    throw vmSecretsUnknownFlag(flag, verb: verb)
                }
                options.values[flag] = value
            } else if valueFlags.contains(arg) {
                guard index + 1 < args.count else {
                    throw CLIError(message: String(format: String(localized: "cloudSecrets.cli.flagNeedsValue", defaultValue: "vm secrets %1$@: %2$@ requires a value"), verb, arg), exitCode: 2)
                }
                index += 1
                options.values[arg] = args[index]
            } else if boolFlags.contains(arg) {
                options.flags.insert(arg)
            } else if arg.hasPrefix("-"), arg != "-" {
                throw vmSecretsUnknownFlag(arg, verb: verb)
            } else {
                options.positional.append(arg)
            }
            index += 1
        }
        return options
    }

    static func parseVMSecretsImport(_ args: [String]) throws -> VMSecretsImportRequest {
        var request = VMSecretsImportRequest()
        var remaining: [String] = []
        var collectingShellNames = false
        for arg in args {
            switch arg {
            case "--from-shell":
                request.fromShell = true
                collectingShellNames = true
            case "--gh":
                request.gh = true
                collectingShellNames = false
            case "--dry-run":
                request.dryRun = true
                collectingShellNames = false
            default:
                if collectingShellNames, !arg.hasPrefix("-") {
                    request.shellNames.append(arg)
                } else {
                    collectingShellNames = false
                    remaining.append(arg)
                }
            }
        }
        request.options = try parseVMSecretsOptions(remaining, verb: "import", valueFlags: ["--scope", "--machine"], boolFlags: ["--project", "--no-sync"])
        guard request.options.positional.count <= 1 else {
            throw CLIError(message: String(format: String(localized: "cloudSecrets.cli.import.oneFile", defaultValue: "vm secrets import: give one .env file (or -)\n\n%@"), vmSecretsUsage), exitCode: 2)
        }
        try refuseVMSecretsInlineAssignments(request.options.positional + request.shellNames, verb: "import")
        request.file = request.options.positional.first
        for name in request.shellNames where !isValidVMEnvKey(name) {
            throw vmSecretsInvalidName(name, verb: "import")
        }
        return request
    }

    /// The scope a command names: `--scope`, `--project[=<key>]`, or `--machine <id>`.
    /// nil when none is given. Two different scopes are an error.
    static func vmSecretsScopeSpec(_ options: VMSecretsOptions) throws -> VMSecretsScopeSpec? {
        var specs: [VMSecretsScopeSpec] = []
        if let raw = options.values["--scope"] {
            specs.append(try parseVMSecretsScope(raw))
        }
        if options.flags.contains("--project") {
            specs.append(.project(nil))
        } else if let key = options.values["--project"] {
            specs.append(.project(key.isEmpty || key == "." ? nil : key))
        }
        if let machine = options.values["--machine"] {
            guard !machine.isEmpty else { throw vmSecretsScopeError(machine) }
            specs.append(.machine(machine))
        }
        guard let first = specs.first else { return nil }
        guard specs.allSatisfy({ $0 == first }) else {
            throw CLIError(message: String(localized: "cloudSecrets.cli.scopeConflict", defaultValue: "vm secrets: give one scope (--scope, --project, or --machine)"), exitCode: 2)
        }
        return first
    }

    /// `all`, `project`, `project:<key>`, `machine:<id>`.
    static func parseVMSecretsScope(_ raw: String) throws -> VMSecretsScopeSpec {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        switch trimmed.lowercased() {
        case "all", "global":
            return .all
        case "project", "project:", "project:.":
            return .project(nil)
        default:
            break
        }
        guard let colon = trimmed.firstIndex(of: ":") else { throw vmSecretsScopeError(raw) }
        let kind = trimmed[..<colon].lowercased()
        let target = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { throw vmSecretsScopeError(raw) }
        switch kind {
        case "project": return .project(target)
        case "machine": return .machine(target)
        default: throw vmSecretsScopeError(raw)
        }
    }

    /// Names for `set`/`rm`: at least one, each valid, and never `NAME=value`.
    static func vmSecretsNames(_ positional: [String], verb: String) throws -> [String] {
        try refuseVMSecretsInlineAssignments(positional, verb: verb)
        guard !positional.isEmpty else {
            throw CLIError(message: String(format: String(localized: "cloudSecrets.cli.namesRequired", defaultValue: "vm secrets %1$@: give at least one NAME\n\n%2$@"), verb, vmSecretsUsage), exitCode: 2)
        }
        for name in positional where !isValidVMEnvKey(name) {
            throw vmSecretsInvalidName(name, verb: verb)
        }
        var seen: Set<String> = []
        return positional.filter { seen.insert($0).inserted }
    }

    /// `NAME=value` on argv is refused before anything else so a value never reaches
    /// the socket from the command line. The message names only the name.
    static func refuseVMSecretsInlineAssignments(_ arguments: [String], verb: String) throws {
        guard let inline = arguments.first(where: { $0.contains("=") && !$0.hasPrefix("-") }) else { return }
        let name = String(inline[..<(inline.firstIndex(of: "=") ?? inline.endIndex)])
        throw CLIError(message: String(
            format: String(localized: "cloudSecrets.cli.inlineRefused", defaultValue: "vm secrets %1$@: refusing %2$@=… on the command line (it would be saved in your shell history and visible in `ps`). Run `cmux vm secrets set %2$@` for a hidden prompt, pipe the value on stdin, or use `cmux vm secrets import <.env>`."),
            verb, name.isEmpty ? "NAME" : name
        ), exitCode: 2)
    }

    /// One value per name, line by line. A trailing newline is not an extra line.
    static func vmSecretsValuesFromStdin(_ text: String, names: [String]) throws -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        lines = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard lines.count == names.count else {
            // English picks the form here; other languages carry plural variations on
            // the first count (scripts/localization-plurals.json).
            let format = names.count == 1
                ? String(localized: "cloudSecrets.cli.set.stdinCount.one", defaultValue: "vm secrets set: expected %1$ld line on stdin (one value per NAME), got %2$ld")
                : String(localized: "cloudSecrets.cli.set.stdinCount", defaultValue: "vm secrets set: expected %1$ld lines on stdin (one value per NAME), got %2$ld")
            throw CLIError(message: String(format: format, names.count, lines.count), exitCode: 2)
        }
        if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw CLIError(message: String(format: String(localized: "cloudSecrets.cli.set.emptyValue", defaultValue: "vm secrets set: the value for %@ is empty"), names[index]), exitCode: 2)
        }
        return lines
    }

    /// A `.env` line `vm secrets import` left out: its number, why, and its name when
    /// the line has a valid one. The line's text is never kept (it may be a value).
    struct VMSecretsDotenvSkip: Equatable {
        enum Reason: String, Equatable {
            case expectedAssignment = "not_assignment"
            case invalidName = "invalid_name"
            case reservedName = "reserved_name"
            case multilineValue = "multiline_value"
            case trailingText = "trailing_text"
            case emptyValue = "empty_value"
        }

        let line: Int
        let reason: Reason
        let name: String?

        /// The stable `--json` code.
        var code: String { reason.rawValue }

        /// "not NAME=value", "empty value".
        var phrase: String {
            switch reason {
            case .expectedAssignment:
                return String(localized: "cloudSecrets.cli.dotenv.skip.expectedAssignment", defaultValue: "not NAME=value")
            case .invalidName:
                return String(localized: "cloudSecrets.cli.dotenv.skip.invalidName", defaultValue: "invalid variable name")
            case .reservedName:
                return String(localized: "cloudSecrets.cli.dotenv.skip.reservedName", defaultValue: "reserved variable name")
            case .multilineValue:
                return String(localized: "cloudSecrets.cli.dotenv.skip.multilineValue", defaultValue: "value spans several lines")
            case .trailingText:
                return String(localized: "cloudSecrets.cli.dotenv.skip.trailingText", defaultValue: "text after the closing quote")
            case .emptyValue:
                return String(localized: "cloudSecrets.cli.dotenv.skip.emptyValue", defaultValue: "empty value")
            }
        }
    }

    /// dotenv for secrets, leniently: the `vm env` rules, but a malformed line, a quote
    /// that never closes, text after a closing quote, or an empty value (`KEY=`) is skipped and reported by line
    /// number instead of failing the file. A repeated name keeps its last good value.
    static func parseVMSecretsDotenv(_ text: String) -> (entries: [VMEnvAssignment], skipped: [VMSecretsDotenvSkip]) {
        var order: [String] = []
        var values: [String: String] = [:]
        var skipped: [VMSecretsDotenvSkip] = []
        for (index, rawLine) in vmEnvFileLines(text).enumerated() {
            let lineNumber = index + 1
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") || line.hasPrefix("export\t") {
                line = String(line.dropFirst("export".count)).trimmingCharacters(in: .whitespaces)
            }
            guard let separator = line.firstIndex(of: "=") else {
                skipped.append(VMSecretsDotenvSkip(line: lineNumber, reason: .expectedAssignment, name: nil))
                continue
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard isValidVMEnvKey(key) else {
                skipped.append(VMSecretsDotenvSkip(line: lineNumber, reason: .invalidName, name: nil))
                continue
            }
            // The machine's env receiver refuses shell and cmux-owned names. Keep
            // dotenv import lenient: one such line must not reject all valid keys.
            if isReservedVMEnvKey(key) {
                skipped.append(VMSecretsDotenvSkip(line: lineNumber, reason: .reservedName, name: key))
                continue
            }
            let rawValue = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            let value: String
            switch parseVMEnvFileValue(rawValue) {
            case .value(let parsed):
                value = parsed
            case .unclosedQuote:
                skipped.append(VMSecretsDotenvSkip(line: lineNumber, reason: .multilineValue, name: key))
                continue
            case .trailingText:
                skipped.append(VMSecretsDotenvSkip(line: lineNumber, reason: .trailingText, name: key))
                continue
            }
            guard !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                skipped.append(VMSecretsDotenvSkip(line: lineNumber, reason: .emptyValue, name: key))
                continue
            }
            if values[key] == nil { order.append(key) }
            values[key] = value
        }
        let entries = order.compactMap { key in values[key].map { VMEnvAssignment(key: key, value: $0) } }
        return (entries, skipped)
    }

    /// `! EMPTY skipped (empty value, line 5)`, or `! line 6 skipped (not NAME=value)`
    /// for a line with no valid name to show.
    static func vmSecretsSkipLines(_ skipped: [VMSecretsDotenvSkip]) -> [String] {
        skipped.map { skip in
            if let name = skip.name {
                return String(
                    format: String(localized: "cloudSecrets.cli.import.skippedNamed", defaultValue: "! %1$@ skipped (%2$@, line %3$ld)"),
                    name, skip.phrase, skip.line
                )
            }
            return String(
                format: String(localized: "cloudSecrets.cli.import.skippedLine", defaultValue: "! line %1$ld skipped (%2$@)"),
                skip.line, skip.phrase
            )
        }
    }

    /// "line 5 (empty value), line 6 (not NAME=value)".
    static func vmSecretsSkipSummaryItems(_ skipped: [VMSecretsDotenvSkip]) -> String {
        skipped.map { skip in
            String(
                format: String(localized: "cloudSecrets.cli.import.skipItem", defaultValue: "line %1$ld (%2$@)"),
                skip.line, skip.phrase
            )
        }.joined(separator: ", ")
    }

    /// "Imported 3 · Skipped 1: line 6 (not NAME=value)"; a dry run says "Would import".
    static func vmSecretsImportSummary(imported: Int, skipped: [VMSecretsDotenvSkip], dryRun: Bool) -> String {
        let format = dryRun
            ? String(localized: "cloudSecrets.cli.import.summaryDryRun", defaultValue: "Would import %1$ld \u{00B7} Skipped %2$ld: %3$@")
            : String(localized: "cloudSecrets.cli.import.summary", defaultValue: "Imported %1$ld \u{00B7} Skipped %2$ld: %3$@")
        return String(format: format, imported, skipped.count, vmSecretsSkipSummaryItems(skipped))
    }

    /// The named variables from `environment`. With `explicit`, unset names are reported
    /// missing; otherwise (well-known names) they are skipped.
    static func vmSecretsShellEntries(
        names: [String],
        environment: [String: String],
        explicit: Bool
    ) -> (entries: [VMEnvAssignment], missing: [String]) {
        var entries: [VMEnvAssignment] = []
        var missing: [String] = []
        for name in names {
            if let value = environment[name], !value.isEmpty {
                entries.append(VMEnvAssignment(key: name, value: value))
            } else if explicit {
                missing.append(name)
            }
        }
        return (entries, missing)
    }

    /// `+ NAME (added)` lines; a dry run says what would happen.
    static func vmSecretsChangeLines(_ changes: [[String: Any]], dryRun: Bool) -> [String] {
        changes.map { change in
            let name = (change["name"] as? String) ?? "?"
            let scope = (change["scope"] as? String) ?? "?"
            let kind = (change["kind"] as? String) ?? "?"
            let mark: String
            switch kind {
            case "added": mark = "+"
            case "updated": mark = "~"
            case "removed": mark = "-"
            default: mark = "="
            }
            let label: String
            switch (kind, dryRun) {
            case ("added", true): label = String(localized: "cloudSecrets.cli.change.wouldAdd", defaultValue: "would add")
            case ("updated", true): label = String(localized: "cloudSecrets.cli.change.wouldUpdate", defaultValue: "would update")
            case ("added", false): label = String(localized: "cloudSecrets.cli.change.added", defaultValue: "added")
            case ("updated", false): label = String(localized: "cloudSecrets.cli.change.updated", defaultValue: "updated")
            case ("removed", _): label = String(localized: "cloudSecrets.cli.change.removed", defaultValue: "removed")
            default: label = String(localized: "cloudSecrets.cli.change.unchanged", defaultValue: "unchanged")
            }
            return "\(mark) \(name) [\(scope)] \(label)"
        }
    }

    /// `NAME  SCOPE  VALUE ID  UPDATED`: the value ID is the keyed fingerprint (it tells
    /// two values apart, never reveals one), and the age is relative ("2h ago").
    /// `--json` keeps the ISO 8601 timestamps.
    static func vmSecretsTable(_ secrets: [[String: Any]], now: Date, locale: Locale = .current) -> String {
        let rows = secrets.map { secret -> [String] in
            [
                (secret["name"] as? String) ?? "?",
                (secret["scope"] as? String) ?? "?",
                "\u{2022}\u{2022}\u{2022}\u{2022}" + ((secret["fingerprint"] as? String) ?? ""),
                vmSecretsAge((secret["updated_at"] as? String) ?? "", now: now, locale: locale),
            ]
        }
        return vmSecretsColumns(header: ["NAME", "SCOPE", "VALUE ID", "UPDATED"], rows: rows)
    }

    /// "just now" under a minute (or for a clock that runs ahead), else "2h ago" in the
    /// locale; an unreadable timestamp is shown as given.
    static func vmSecretsAge(_ iso: String, now: Date, locale: Locale = .current) -> String {
        let formatter = ISO8601DateFormatter()
        var date = formatter.date(from: iso)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = formatter.date(from: iso)
        }
        guard let date else { return iso }
        guard now.timeIntervalSince(date) >= 60 else {
            return String(localized: "cloudSecrets.cli.ls.justNow", defaultValue: "just now")
        }
        let relative = RelativeDateTimeFormatter()
        relative.locale = locale
        relative.unitsStyle = .abbreviated
        relative.dateTimeStyle = .numeric
        return relative.localizedString(for: date, relativeTo: now)
    }

    /// One name a sync changed on a machine: `added`, `updated`, or `removed`.
    struct VMSecretsSyncChange: Equatable {
        let name: String
        let kind: String
    }

    /// What a `vm.secrets_sync` result changed, given the machine's status rows from
    /// before it: a delivered name that was missing is added, one that was stale is
    /// updated, one that was current is unchanged. Without `before`, every delivered
    /// name counts as updated (the result cannot tell new from rewritten).
    static func vmSecretsSyncChanges(result: [String: Any], before: [[String: Any]]?) -> [VMSecretsSyncChange] {
        guard (result["noop"] as? Bool) != true else { return [] }
        var states: [String: String] = [:]
        for row in before ?? [] {
            if let name = row["name"] as? String, let state = row["state"] as? String { states[name] = state }
        }
        var changes: [VMSecretsSyncChange] = []
        for name in (result["sent"] as? [String]) ?? [] {
            guard before != nil else {
                changes.append(VMSecretsSyncChange(name: name, kind: "updated"))
                continue
            }
            switch states[name] {
            case "current": continue
            case "stale": changes.append(VMSecretsSyncChange(name: name, kind: "updated"))
            default: changes.append(VMSecretsSyncChange(name: name, kind: "added"))
            }
        }
        for name in (result["removed"] as? [String]) ?? [] {
            changes.append(VMSecretsSyncChange(name: name, kind: "removed"))
        }
        return changes
    }

    /// "Synced 1 change to brave-otter: OPENAI_API_KEY updated" plus the new-terminal
    /// reminder, or "brave-otter is up to date." when nothing changed.
    static func vmSecretsSyncReport(machine: String, changes: [VMSecretsSyncChange], noop: Bool) -> [String] {
        guard !changes.isEmpty else {
            return [String(format: String(localized: "cloudSecrets.cli.sync.current", defaultValue: "%@ is up to date."), machine)]
        }
        return [
            vmSecretsSyncedLine(machine: machine, changes: changes),
            String(localized: "cloudSecrets.cli.sync.newTerminals", defaultValue: "Open a new terminal on the machine to use the updated values."),
        ]
    }

    static func vmSecretsSyncedLine(machine: String, changes: [VMSecretsSyncChange]) -> String {
        let items = changes.map { change -> String in
            let kind: String
            switch change.kind {
            case "added": kind = String(localized: "cloudSecrets.cli.change.added", defaultValue: "added")
            case "removed": kind = String(localized: "cloudSecrets.cli.change.removed", defaultValue: "removed")
            default: kind = String(localized: "cloudSecrets.cli.change.updated", defaultValue: "updated")
            }
            return "\(change.name) \(kind)"
        }.joined(separator: ", ")
        let format = changes.count == 1
            ? String(localized: "cloudSecrets.cli.sync.changed.one", defaultValue: "Synced %1$ld change to %2$@: %3$@")
            : String(localized: "cloudSecrets.cli.sync.changed.many", defaultValue: "Synced %1$ld changes to %2$@: %3$@")
        return String(format: format, changes.count, machine, items)
    }

    /// The scope as words for a message: "all machines", "project github.com/o/r",
    /// "this project", "machine brave-otter".
    static func vmSecretsScopePhrase(_ spec: VMSecretsScopeSpec) -> String {
        switch spec {
        case .all:
            return String(localized: "cloudSecrets.cli.scopePhrase.all", defaultValue: "all machines")
        case .project(nil):
            return String(localized: "cloudSecrets.cli.scopePhrase.thisProject", defaultValue: "this project")
        case .project(let key?):
            return String(format: String(localized: "cloudSecrets.cli.scopePhrase.project", defaultValue: "project %@"), key)
        case .machine(let id):
            return String(format: String(localized: "cloudSecrets.cli.scopePhrase.machine", defaultValue: "machine %@"), id)
        }
    }

    static func vmSecretsStatusTable(_ rows: [[String: Any]]) -> String {
        vmSecretsColumns(header: ["NAME", "STATE", "SCOPE"], rows: rows.map { row in
            [
                (row["name"] as? String) ?? "?",
                (row["state"] as? String) ?? "?",
                (row["scope"] as? String) ?? "-",
            ]
        })
    }

    private static func vmSecretsColumns(header: [String], rows: [[String]]) -> String {
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        return all.map { row in
            row.enumerated().map { column, cell in
                column == row.count - 1 ? cell : cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    private static func vmSecretsUnknownFlag(_ flag: String, verb: String) -> CLIError {
        CLIError(message: String(format: String(localized: "cloudSecrets.cli.unknownFlag", defaultValue: "vm secrets %1$@: unknown flag '%2$@'\n\n%3$@"), verb, flag, vmSecretsUsage), exitCode: 2)
    }

    /// The name is not shown: text in the name position can be a pasted value.
    private static func vmSecretsInvalidName(_ name: String, verb: String) -> CLIError {
        CLIError(message: String(format: String(localized: "cloudSecrets.cli.invalidNameHidden", defaultValue: "vm secrets %@: a name is not a valid variable name (names match [A-Za-z_][A-Za-z0-9_]*)"), verb), exitCode: 2)
    }

    private static func vmSecretsScopeError(_ raw: String) -> CLIError {
        CLIError(message: String(format: String(localized: "cloudSecrets.cli.invalidScope", defaultValue: "vm secrets: unknown scope '%@' (use all, project, project:<key>, or machine:<id>)"), raw), exitCode: 2)
    }
}

/// The terminal settings to restore if a signal arrives while a hidden prompt is open.
/// Written only around `readVMSecretHidden`, read only by the signal handlers below.
nonisolated(unsafe) private var vmSecretsSavedTermios: termios?
/// The prompt's own settings (echo and canonical mode off), re-applied after Ctrl-Z.
nonisolated(unsafe) private var vmSecretsHiddenTermios: termios?

/// Ctrl-Z while the prompt is open: show echo again for the shell, stop, and hide
/// input again once the job is continued. tcsetattr is async-signal-safe.
private func vmSecretsSuspendWithTerminalRestored(_ signalNumber: Int32) {
    if var saved = vmSecretsSavedTermios {
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &saved)
    }
    signal(SIGTSTP, SIG_DFL)
    // The handler runs with SIGTSTP blocked; unblock it so raise() stops the process now.
    var unblock = sigset_t()
    sigemptyset(&unblock)
    sigaddset(&unblock, SIGTSTP)
    _ = sigprocmask(SIG_UNBLOCK, &unblock, nil)
    raise(SIGTSTP)
    // Continued.
    signal(SIGTSTP, vmSecretsSuspendWithTerminalRestored)
    if var hidden = vmSecretsHiddenTermios {
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &hidden)
    }
}

/// Restores echo, then re-raises the signal with its default action so the shell sees
/// the usual exit status.
private func vmSecretsRestoreTerminalAndExit(_ signalNumber: Int32) {
    if var saved = vmSecretsSavedTermios {
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &saved)
    }
    _ = write(STDERR_FILENO, "\n", 1)
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}
