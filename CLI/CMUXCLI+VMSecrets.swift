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
        Usage:
          cmux vm secrets [ls] [--scope <scope>] [--json]
                                                              List stored secrets: name, scope, fingerprint, last update.
                                                              Values are never shown.
          cmux vm secrets set NAME [NAME2 …] [--scope <scope>] [--project] [--machine <id>] [--no-sync]
                                                              Store secrets. Each value is read from a hidden prompt, or,
                                                              when stdin is not a terminal, one line per NAME from stdin.
                                                              NAME=value on the command line is refused: it would land in
                                                              your shell history and `ps`.
          cmux vm secrets import [<.env>|-] [--from-shell [NAME …]] [--gh] [--scope <scope>] [--dry-run] [--no-sync]
                                                              Import a .env file (or - for stdin), variables from this
                                                              shell (--from-shell alone takes every well-known agent key
                                                              that is set), or GitHub CLI's token as GH_TOKEN (--gh).
                                                              --dry-run shows what would be added or updated.
          cmux vm secrets rm NAME [NAME2 …] [--scope <scope>] [--no-sync]
                                                              Remove secrets from the vault and from synced machines.
          cmux vm secrets sync <machine> [--project <key>|.]  Deliver the secrets that apply to a machine now.
                                                              --project links it to a project first.
          cmux vm secrets status <machine> [--verify] [--json]
                                                              Per name: current, stale, missing, or extra on the machine.
                                                              --verify reads the machine's env file (names only).
          cmux vm secrets check [<dir>]                       Compare the names a repository declares (.cmux/cloud.json,
                                                              .devcontainer secrets) with the vault.
          cmux vm secrets link <machine> [--project <key>|.]  Apply a project's secrets to a machine (default: this
          cmux vm secrets unlink <machine> [--project <key>|.]
                                                              directory's git remote).

        Scopes (the most specific wins when a name is stored more than once):
          all                 every Cloud machine you use from this Mac (default)
          project[:<key>]     machines linked to a project; the key is the git remote as host/owner/repo,
                              and --project or a bare `project` means this directory's remote
          machine:<id>        one machine (same as --machine <id>)

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
            params.merge(vmSecretsScopeParams(spec, directory: FileManager.default.currentDirectoryPath)) { _, new in new }
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
        print(Self.vmSecretsTable(secrets))
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
        let spec = try Self.vmSecretsScopeSpec(options) ?? .all
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
            client: client,
            json: json
        )
    }

    private func runVMSecretsImport(_ args: [String], client: SocketClient, json: Bool) throws {
        let request = try Self.parseVMSecretsImport(args)
        let spec = try Self.vmSecretsScopeSpec(request.options) ?? .all
        var entries: [VMEnvAssignment] = []
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
            entries += try Self.parseVMSecretsDotenv(text)
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
            client: client,
            json: json
        )
    }

    private func runVMSecretsRemove(_ args: [String], client: SocketClient, json: Bool) throws {
        let options = try Self.parseVMSecretsOptions(args, verb: "rm", valueFlags: ["--scope", "--machine"], boolFlags: ["--project", "--no-sync"])
        let names = try Self.vmSecretsNames(options.positional, verb: "rm")
        let spec = try Self.vmSecretsScopeSpec(options) ?? .all
        var params = vmSecretsScopeParams(spec, directory: FileManager.default.currentDirectoryPath)
        params["names"] = names
        if options.flags.contains("--no-sync") { params["sync"] = false }
        let response = try client.sendV2(method: "vm.secrets_rm", params: params, responseTimeout: Self.vmSecretsResponseTimeout)
        if json {
            print(jsonString(response))
            return
        }
        let removed = ((response["changes"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        if removed.isEmpty {
            print(String(format: String(localized: "cloudSecrets.cli.rm.none", defaultValue: "Nothing removed: %@ not stored in that scope."), names.joined(separator: ", ")))
        } else {
            print(String(format: String(localized: "cloudSecrets.cli.rm.done", defaultValue: "OK removed %@"), removed.joined(separator: ", ")))
        }
        printVMSecretsSyncLines((response["synced"] as? [[String: Any]]) ?? [])
    }

    private func runVMSecretsSync(_ args: [String], client: SocketClient, json: Bool) throws {
        let options = try Self.parseVMSecretsOptions(args, verb: "sync", valueFlags: ["--project"], boolFlags: [])
        guard options.positional.count == 1, let machine = options.positional.first else {
            throw CLIError(message: Self.vmSecretsUsage, exitCode: 2)
        }
        var params: [String: Any] = ["id": machine]
        if let project = options.values["--project"] {
            params.merge(vmSecretsProjectParams(project, directory: FileManager.default.currentDirectoryPath)) { _, new in new }
        }
        let response = try client.sendV2(method: "vm.secrets_sync", params: params, responseTimeout: 260)
        if json {
            print(jsonString(response))
        } else {
            printVMSecretsSyncLines([response], reportNoop: true)
        }
        if let error = response["error"] as? String, !error.isEmpty {
            throw CLIError(message: String(format: String(localized: "cloudSecrets.cli.sync.failed", defaultValue: "vm secrets sync: %@"), error))
        }
    }

    private func runVMSecretsStatus(_ args: [String], client: SocketClient, json: Bool) throws {
        let options = try Self.parseVMSecretsOptions(args, verb: "status", valueFlags: [], boolFlags: ["--verify"])
        guard options.positional.count == 1, let machine = options.positional.first else {
            throw CLIError(message: Self.vmSecretsUsage, exitCode: 2)
        }
        let response = try client.sendV2(
            method: "vm.secrets_status",
            params: ["id": machine, "verify": options.flags.contains("--verify")],
            responseTimeout: 120
        )
        if json {
            print(jsonString(response))
            return
        }
        let rows = (response["rows"] as? [[String: Any]]) ?? []
        if rows.isEmpty {
            print(String(format: String(localized: "cloudSecrets.cli.status.empty", defaultValue: "No Cloud Secrets apply to %@."), machine))
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
        guard options.positional.count == 1, let machine = options.positional.first else {
            throw CLIError(message: Self.vmSecretsUsage, exitCode: 2)
        }
        var params: [String: Any] = ["id": machine]
        params.merge(vmSecretsProjectParams(options.values["--project"] ?? ".", directory: FileManager.default.currentDirectoryPath)) { _, new in new }
        guard params["project"] != nil || params["project_remote_url"] != nil || params["project_dir_name"] != nil else {
            throw CLIError(message: Self.vmSecretsUsage, exitCode: 2)
        }
        if options.flags.contains("--no-sync") { params["sync"] = false }
        let response = try client.sendV2(method: "vm.secrets_\(verb)", params: params, responseTimeout: 260)
        if json {
            print(jsonString(response))
            return
        }
        let project = (response["project"] as? String) ?? "?"
        let format = linking
            ? String(localized: "cloudSecrets.cli.link.done", defaultValue: "OK linked %1$@ to %2$@")
            : String(localized: "cloudSecrets.cli.unlink.done", defaultValue: "OK unlinked %1$@ from %2$@")
        print(String(format: format, machine, project))
        if let sync = response["sync"] as? [String: Any] {
            printVMSecretsSyncLines([sync])
        }
    }

    // MARK: - `vm agent` hook

    /// Brings the agent's machine up to date before the agent starts, linking it to the
    /// working directory's project when it has a git remote. Never fatal: a failure is
    /// one stderr line and the agent starts anyway.
    func syncVMSecretsBeforeAgent(machine: String, workDirectory: String, client: SocketClient) {
        var params: [String: Any] = ["id": machine]
        if let remote = Self.vmSecretsGitRemoteURL(directory: workDirectory) {
            params["project_remote_url"] = remote
        }
        do {
            let response = try client.sendV2(method: "vm.secrets_sync", params: params, responseTimeout: 260)
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
        guard let response = try? client.sendV2(method: "vm.secrets_check", params: params, responseTimeout: 60) else {
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
        client: SocketClient,
        json: Bool
    ) throws {
        var params = vmSecretsScopeParams(spec, directory: FileManager.default.currentDirectoryPath)
        // Values cross only the authenticated local socket; the app answers with names.
        params["entries"] = entries.map { ["key": $0.key, "value": $0.value] }
        params["source"] = source
        if let sync { params["sync"] = sync }
        if dryRun { params["dry_run"] = true }
        let response = try client.sendV2(method: "vm.secrets_set", params: params, responseTimeout: Self.vmSecretsResponseTimeout)
        if json {
            print(jsonString(response))
            return
        }
        let changes = (response["changes"] as? [[String: Any]]) ?? []
        for line in Self.vmSecretsChangeLines(changes, dryRun: dryRun) {
            print(line)
        }
        printVMSecretsSyncLines((response["synced"] as? [[String: Any]]) ?? [])
    }

    private func printVMSecretsSyncLines(_ results: [[String: Any]], reportNoop: Bool = false) {
        for result in results {
            let machine = (result["machine"] as? String) ?? "?"
            if let error = result["error"] as? String, !error.isEmpty {
                print(String(format: String(localized: "cloudSecrets.cli.sync.machineFailed", defaultValue: "%1$@: sync failed: %2$@"), machine, error))
                continue
            }
            let sent = (result["sent"] as? [String]) ?? []
            let removed = (result["removed"] as? [String]) ?? []
            if (result["noop"] as? Bool) == true {
                if reportNoop {
                    print(String(format: String(localized: "cloudSecrets.cli.sync.current", defaultValue: "%@ is up to date."), machine))
                }
                continue
            }
            if !sent.isEmpty {
                print(String(format: String(localized: "cloudSecrets.cli.sync.sent", defaultValue: "%1$@: delivered %2$@"), machine, sent.joined(separator: ", ")))
            }
            if !removed.isEmpty {
                print(String(format: String(localized: "cloudSecrets.cli.sync.removed", defaultValue: "%1$@: removed %2$@"), machine, removed.joined(separator: ", ")))
            }
        }
        if results.contains(where: { ($0["noop"] as? Bool) != true && ($0["error"] as? String) == nil }) {
            print(String(localized: "cloudSecrets.cli.sync.newTerminals", defaultValue: "Open a new terminal on the machine to use the updated values."))
        }
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
    /// through a signal handler, on Ctrl-C or termination while the prompt is open.
    static func readVMSecretHidden(prompt: String) throws -> String {
        cliWriteStderr(prompt)
        var original = termios()
        let hasTerminal = tcgetattr(STDIN_FILENO, &original) == 0
        var previousInt: (@convention(c) (Int32) -> Void)?
        var previousTerm: (@convention(c) (Int32) -> Void)?
        if hasTerminal {
            vmSecretsSavedTermios = original
            previousInt = signal(SIGINT, vmSecretsRestoreTerminalAndExit)
            previousTerm = signal(SIGTERM, vmSecretsRestoreTerminalAndExit)
            var hidden = original
            hidden.c_lflag &= ~tcflag_t(ECHO)
            _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden)
        }
        defer {
            if hasTerminal {
                _ = tcsetattr(STDIN_FILENO, TCSANOW, &original)
                signal(SIGINT, previousInt ?? SIG_DFL)
                signal(SIGTERM, previousTerm ?? SIG_DFL)
                vmSecretsSavedTermios = nil
            }
            cliWriteStderr("\n")
        }
        guard let line = readLine(strippingNewline: true) else {
            throw CLIError(message: String(localized: "cloudSecrets.cli.set.noInput", defaultValue: "vm secrets set: no value entered"), exitCode: 2)
        }
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
            throw CLIError(message: String(format: String(localized: "cloudSecrets.cli.set.stdinCount", defaultValue: "vm secrets set: expected %1$ld line(s) on stdin, one value per NAME, got %2$ld"), names.count, lines.count), exitCode: 2)
        }
        if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw CLIError(message: String(format: String(localized: "cloudSecrets.cli.set.emptyValue", defaultValue: "vm secrets set: the value for %@ is empty"), names[index]), exitCode: 2)
        }
        return lines
    }

    /// dotenv for secrets: the `vm env` rules, but an error names the line number only,
    /// never its content (a malformed line can be a bare token).
    static func parseVMSecretsDotenv(_ text: String) throws -> [VMEnvAssignment] {
        var assignments: [VMEnvAssignment] = []
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") || line.hasPrefix("export\t") {
                line = String(line.dropFirst("export".count)).trimmingCharacters(in: .whitespaces)
            }
            guard let separator = line.firstIndex(of: "=") else {
                throw CLIError(message: String(format: String(localized: "cloudSecrets.cli.dotenv.expected", defaultValue: "vm secrets import: line %ld is not NAME=value"), index + 1), exitCode: 2)
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard isValidVMEnvKey(key) else {
                throw CLIError(message: String(format: String(localized: "cloudSecrets.cli.dotenv.invalidName", defaultValue: "vm secrets import: line %ld has an invalid variable name"), index + 1), exitCode: 2)
            }
            let value = parseVMEnvFileValue(line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces))
            assignments.append(VMEnvAssignment(key: key, value: value))
        }
        return assignments
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

    static func vmSecretsTable(_ secrets: [[String: Any]]) -> String {
        let rows = secrets.map { secret -> [String] in
            [
                (secret["name"] as? String) ?? "?",
                (secret["scope"] as? String) ?? "?",
                "••••" + ((secret["fingerprint"] as? String) ?? ""),
                (secret["updated_at"] as? String) ?? "",
            ]
        }
        return vmSecretsColumns(header: ["NAME", "SCOPE", "FINGERPRINT", "UPDATED"], rows: rows)
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

    private static func vmSecretsInvalidName(_ name: String, verb: String) -> CLIError {
        CLIError(message: String(format: String(localized: "cloudSecrets.cli.invalidName", defaultValue: "vm secrets %1$@: invalid variable name '%2$@' (names match [A-Za-z_][A-Za-z0-9_]*)"), verb, name), exitCode: 2)
    }

    private static func vmSecretsScopeError(_ raw: String) -> CLIError {
        CLIError(message: String(format: String(localized: "cloudSecrets.cli.invalidScope", defaultValue: "vm secrets: unknown scope '%@' (use all, project, project:<key>, or machine:<id>)"), raw), exitCode: 2)
    }
}

/// The terminal settings to restore if a signal arrives while a hidden prompt is open.
/// Written only around `readVMSecretHidden`, read only by the signal handler below.
nonisolated(unsafe) private var vmSecretsSavedTermios: termios?

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
