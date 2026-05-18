import Foundation

extension CMUXCLI {
    private struct CLIActionPort {
        let name: String
        let port: Int
        let url: String
    }

    private struct CLIActionSummary {
        let id: String
        let title: String
        let defaultRef: String
        let modes: [String]
        let ports: [CLIActionPort]
    }

    private static let builtInActionSummaries: [CLIActionSummary] = [
        CLIActionSummary(
            id: "hexclave/stack-auth:fresh-env",
            title: "Fresh Stack Auth environment",
            defaultRef: "dev",
            modes: ["full", "basic"],
            ports: [
                CLIActionPort(name: "Launchpad", port: 8100, url: "http://localhost:8100"),
                CLIActionPort(name: "Dashboard", port: 8101, url: "http://localhost:8101"),
                CLIActionPort(name: "Backend", port: 8102, url: "http://localhost:8102"),
            ]
        )
    ]

    static func actionsCommandDoesNotNeedSocket(_ commandArgs: [String]) -> Bool {
        let sub = commandArgs.first?.lowercased() ?? "list"
        if sub != "run" { return true }
        let rest = Array(commandArgs.dropFirst())
        guard let action = rest.first else { return true }
        return isFlagToken(action)
    }

    func runActionsNoSocket(commandArgs: [String], jsonOutput: Bool) throws {
        let sub = commandArgs.first?.lowercased() ?? "list"
        let rest = Array(commandArgs.dropFirst())
        switch sub {
        case "list":
            if let extra = rest.first {
                throw CLIError(message: "actions list: unexpected argument '\(extra)'.")
            }
            printActionsList(jsonOutput: jsonOutput)
        case "run":
            throw CLIError(message: """
                Usage: cmux actions run <action> [--ref <ref>] [--mode full|basic] [--dry-run] [--keep] [--no-cache] [--detach]

                Try:
                  cmux actions run hexclave/stack-auth:fresh-env
                """)
        case "help", "--help", "-h":
            print(subcommandUsage("actions") ?? "Usage: cmux actions <list|run> [args...]")
        default:
            throw CLIError(message: """
                Unknown actions subcommand '\(sub)'.

                Run `cmux actions list` to see available actions.
                Run `cmux actions --help` for usage.
                """)
        }
    }

    func runActionsCommand(
        commandArgs: [String],
        jsonOutput: Bool,
        client: SocketClient,
        idFormat: CLIIDFormat
    ) throws {
        let sub = commandArgs.first?.lowercased() ?? "list"
        let rest = Array(commandArgs.dropFirst())
        switch sub {
        case "list":
            printActionsList(jsonOutput: jsonOutput)

        case "run":
            try runActionCommand(rest: rest, jsonOutput: jsonOutput, client: client, idFormat: idFormat)

        default:
            throw CLIError(message: """
                Usage: cmux actions <list|run> [args...]

                Examples:
                  cmux actions list
                  cmux actions run hexclave/stack-auth:fresh-env
                """)
        }
    }

    private func runActionCommand(
        rest: [String],
        jsonOutput: Bool,
        client: SocketClient,
        idFormat: CLIIDFormat
    ) throws {
        guard let action = rest.first, !Self.isFlagToken(action) else {
            throw CLIError(message: """
                Usage: cmux actions run <action> [--ref <ref>] [--mode full|basic] [--dry-run] [--keep] [--no-cache] [--detach]

                Try:
                  cmux actions run hexclave/stack-auth:fresh-env
                """)
        }
        let actionArgs = Array(rest.dropFirst())
        let (refOpt, rem0) = parseOption(actionArgs, name: "--ref")
        let (modeOpt, rem1) = parseOption(rem0, name: "--mode")
        let dryRun = hasFlag(rem1, name: "--dry-run")
        let keep = hasFlag(rem1, name: "--keep")
        let noCache = hasFlag(rem1, name: "--no-cache")
        let detach = hasFlag(rem1, name: "--detach") || hasFlag(rem1, name: "-d")
        let remaining = rem1.filter {
            $0 != "--dry-run" &&
            $0 != "--keep" &&
            $0 != "--no-cache" &&
            $0 != "--detach" &&
            $0 != "-d"
        }
        if let unknown = remaining.first(where: { Self.isUnknownFlagToken($0, allowedShortFlags: ["-d"]) }) {
            throw CLIError(message: """
                actions run: unknown flag '\(unknown)'.

                Known flags:
                  --ref <ref>
                  --mode full|basic
                  --dry-run
                  --keep
                  --no-cache
                  --detach, -d
                """)
        }
        if let extra = remaining.first(where: { !Self.isFlagToken($0) }) {
            throw CLIError(message: """
                actions run: unexpected argument '\(extra)'.

                Try:
                  cmux actions run \(action)
                """)
        }
        let normalizedMode: String?
        if let modeOpt {
            let lowered = modeOpt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard lowered == "full" || lowered == "basic" else {
                throw CLIError(message: "actions run: --mode must be `full` or `basic`.")
            }
            normalizedMode = lowered
        } else {
            normalizedMode = nil
        }
        let idempotency = try Self.activeVMCreateIdempotency(
            image: "action:\(action):\(refOpt ?? ""):\(normalizedMode ?? ""):\(noCache ? "no-cache" : "cache")",
            provider: "freestyle"
        )
        var params: [String: Any] = [
            "action": action,
            "dry_run": dryRun,
            "keep": keep,
            "no_cache": noCache,
            "idempotency_key": idempotency.key,
        ]
        if let refOpt { params["ref"] = refOpt }
        if let normalizedMode { params["mode"] = normalizedMode }
        let response = try client.sendV2(
            method: "actions.run",
            params: params,
            responseTimeout: dryRun ? 30 : Self.vmCreateResponseTimeoutSeconds
        )
        try validateActionRunResponse(response)
        defer { Self.clearVMCreateIdempotency(idempotency) }

        if jsonOutput {
            print(jsonString(sanitizedActionRunResponse(response)))
            return
        }
        printActionRunSummary(response)
        guard !dryRun, !detach, let vmId = response["vm_id"] as? String, !vmId.isEmpty else {
            return
        }
        let shortId = String(vmId.prefix(8))
        try vmOpenShell(
            id: vmId,
            workspaceName: "action:\(shortId)",
            client: client,
            jsonOutput: jsonOutput,
            idFormat: idFormat
        )
    }

    private func validateActionRunResponse(_ response: [String: Any]) throws {
        guard let rawPorts = response["ports"] else { return }
        guard let ports = rawPorts as? [[String: Any]] else {
            throw CLIError(message: "Cloud action response included invalid port data.")
        }
        for port in ports {
            guard port["name"] is String,
                  port["url"] is String,
                  let portNumber = Self.actionRunPortNumber(port["port"]),
                  (1...65_535).contains(portNumber) else {
                throw CLIError(message: "Cloud action response included an invalid port.")
            }
        }
    }

    private static func actionRunPortNumber(_ raw: Any?) -> Int? {
        if let int = raw as? Int {
            return int
        }
        if let double = raw as? Double {
            return Int(exactly: double)
        }
        return nil
    }

    private func sanitizedActionRunResponse(_ response: [String: Any]) -> [String: Any] {
        var sanitized = response
        sanitized.removeValue(forKey: "setup_script")
        sanitized.removeValue(forKey: "start_script")
        if let cache = response["cache"] as? [String: Any] {
            sanitized["cache"] = ["hit": (cache["hit"] as? Bool) ?? false]
        }
        return sanitized
    }

    private func printActionRunSummary(_ response: [String: Any]) {
        let title = (response["title"] as? String) ?? (response["action"] as? String) ?? "Action"
        let action = (response["action"] as? String) ?? "hexclave/stack-auth:fresh-env"
        let ref = (response["ref"] as? String) ?? "?"
        let mode = (response["mode"] as? String) ?? "full"
        let dryRun = (response["dry_run"] as? Bool) ?? false
        let started = (response["started"] as? Bool) ?? false
        let setupRan = (response["setup_ran"] as? Bool) ?? false
        let cache = response["cache"] as? [String: Any] ?? [:]
        let cacheHit = (cache["hit"] as? Bool) ?? false

        if dryRun {
            print("\(title)")
            print("  ref:        \(ref)")
            print("  mode:       \(mode)")
            print("")
            print("Dry run complete. No Cloud VM was created.")
            print("Run `cmux actions run \(action)` to create the environment.")
            return
        }

        print("\(started ? "Started" : "Prepared") \(title)")
        if let vmId = response["vm_id"] as? String {
            print("  vm:         \(vmId)")
        }
        print("  ref:        \(ref)")
        print("  mode:       \(mode)")
        print("  cache:      \(cacheHit ? "hit" : (setupRan ? "created" : "miss"))")
        let ports = response["ports"] as? [[String: Any]] ?? []
        if !ports.isEmpty {
            print("")
            print("Ports:")
            for port in ports {
                let name = (port["name"] as? String) ?? "Port"
                let url = (port["url"] as? String) ?? ""
                print("  \(name): \(url)")
            }
        }
        let instructions = response["instructions"] as? [String] ?? []
        if !instructions.isEmpty {
            print("")
            print("Next:")
            for instruction in instructions {
                print("  \(instruction)")
            }
        }
    }

    private func printActionsList(jsonOutput: Bool) {
        if jsonOutput {
            let actions = Self.builtInActionSummaries.map { action in
                [
                    "id": action.id,
                    "title": action.title,
                    "default_ref": action.defaultRef,
                    "modes": action.modes,
                    "ports": action.ports.map { port in
                        [
                            "name": port.name,
                            "port": port.port,
                            "url": port.url,
                        ] as [String: Any]
                    },
                ] as [String: Any]
            }
            print(jsonString(["actions": actions]))
            return
        }
        for action in Self.builtInActionSummaries {
            print("\(action.id)  \(action.title)")
            print("  default ref: \(action.defaultRef)")
            print("  modes:       \(action.modes.joined(separator: ", "))")
            print("  ports:       \(action.ports.map { "\($0.name) \($0.port)" }.joined(separator: ", "))")
        }
    }
}
