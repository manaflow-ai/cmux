import Foundation

/// The socket-backed half of `cmux orchestration`: `plan` and `run`.
///
/// Both call `orchestration.plan` first so the CLI can show exactly what
/// would happen (workspaces, agent commands, scripts, substrate). `run`
/// then enforces the trust gate: the first run of a template requires an
/// explicit confirmation (or `--yes`) before `orchestration.run` executes.
extension CMUXCLI {
    func runOrchestrationSocketNamespace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        guard let subcommand = commandArgs.first?.lowercased() else {
            throw CLIError(message: "orchestration requires a subcommand. Try: cmux orchestration --help")
        }
        let rest = Array(commandArgs.dropFirst())
        switch subcommand {
        case "plan":
            try runOrchestrationRun(commandArgs: rest + ["--dry-run"], client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowOverride)
        case "run":
            try runOrchestrationRun(commandArgs: rest, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowOverride)
        default:
            throw CLIError(message: "Unknown orchestration subcommand: \(subcommand). Try: cmux orchestration --help")
        }
    }

    private func runOrchestrationRun(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (tasks, rem0) = parseRepeatedOption(commandArgs, name: "--task")
        let (tasksFileOpt, rem1) = parseOption(rem0, name: "--tasks-file")
        let (paramValues, rem2) = parseRepeatedOption(rem1, name: "--param")
        let (agentOpt, rem3) = parseOption(rem2, name: "--agent")
        let (windowOpt, rem4) = parseOption(rem3, name: "--window")
        let dryRun = hasFlag(rem4, name: "--dry-run")
        let assumeYes = hasFlag(rem4, name: "--yes") || hasFlag(rem4, name: "-y")
        let remaining = rem4.filter { !["--dry-run", "--yes", "-y", "--json"].contains($0) }
        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "orchestration run: unknown flag '\(unknown)'")
        }
        guard let name = remaining.first?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw CLIError(message: "orchestration run requires <name>")
        }
        let effectiveJSONOutput = jsonOutput || hasFlag(rem4, name: "--json")

        var taskTitles = tasks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let tasksFileOpt {
            let contents = try String(contentsOfFile: resolvePath(tasksFileOpt), encoding: .utf8)
            for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                taskTitles.append(trimmed)
            }
        }
        guard !taskTitles.isEmpty else {
            throw CLIError(message: "orchestration run requires at least one --task or --tasks-file entry")
        }

        var overrides: [String: String] = [:]
        for pair in paramValues {
            guard let equals = pair.firstIndex(of: "=") else {
                throw CLIError(message: "--param expects key=value, got '\(pair)'")
            }
            overrides[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
        }

        var params: [String: Any] = [
            "name": name,
            "tasks": taskTitles,
        ]
        if !overrides.isEmpty { params["params"] = overrides }
        if let agentOpt { params["agent"] = agentOpt }
        let windowHandle = try normalizeWindowHandle(windowOpt ?? windowOverride, client: client)
        if let windowHandle { params["window_id"] = windowHandle }

        let planPayload = try client.sendV2(method: "orchestration.plan", params: params)
        let plan = planPayload["plan"] as? [String: Any] ?? [:]
        let trustConfirmed = planPayload["trust_confirmed"] as? Bool ?? false
        let trustFingerprint = planPayload["trust_fingerprint"] as? String

        if effectiveJSONOutput, dryRun {
            print(jsonString(planPayload))
            return
        }
        printOrchestrationPlan(plan, trustConfirmed: trustConfirmed)
        if dryRun {
            return
        }

        if !trustConfirmed && !assumeYes {
            guard isatty(fileno(stdin)) != 0 else {
                throw CLIError(message: "First run of '\(name)' needs trust confirmation. Re-run with --yes after reviewing the plan above.")
            }
            print("First run of this template. It will type the agent commands above into real terminals" +
                  (orchestrationPlanHasScripts(plan) ? " and execute the listed template scripts" : "") + ".")
            print("Proceed? [y/N]: ", terminator: "")
            let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard answer == "y" || answer == "yes" else {
                print("Aborted.")
                return
            }
        }

        params["confirm_trust"] = true
        // Echo the reviewed plan's fingerprint so the app rejects the run if
        // the template changed between plan and confirmation.
        if let trustFingerprint {
            params["confirm_fingerprint"] = trustFingerprint
        }
        let runPayload = try client.sendV2(method: "orchestration.run", params: params)
        if effectiveJSONOutput {
            print(jsonString(runPayload))
            return
        }
        let group = runPayload["group"] as? String ?? ""
        let workspaces = runPayload["workspaces"] as? [[String: Any]] ?? []
        let runID = ((runPayload["run_id"] as? String) ?? "").prefix(6)
        print("Started run \(runID) — \(workspaces.count) workspace(s) provisioning in group \"\(group)\"")
        for note in runPayload["notes"] as? [String] ?? [] {
            print("note: \(note)")
        }
    }

    private func orchestrationPlanHasScripts(_ plan: [String: Any]) -> Bool {
        guard let trust = plan["trust"] as? [String: Any],
              let scripts = trust["scriptPaths"] as? [String] else { return false }
        return !scripts.isEmpty
    }

    private func printOrchestrationPlan(_ plan: [String: Any], trustConfirmed: Bool) {
        let name = plan["orchestrationName"] as? String ?? ""
        let runID = (plan["runID"] as? String).map { String($0.prefix(6)) } ?? ""
        print("Plan: \(name) run \(runID)")
        if let group = plan["groupName"] as? String { print("Group: \(group)") }
        if let agent = plan["agentID"] as? String { print("Agent: \(agent)") }
        if let root = plan["workspaceRoot"] as? String { print("Workspace root: \(root)") }
        if let trust = plan["trust"] as? [String: Any] {
            if let substrate = trust["substrate"] as? String { print("Substrate: \(substrate)") }
            if let scripts = trust["scriptPaths"] as? [String], !scripts.isEmpty {
                print("Template scripts that will run on your machine:")
                for script in scripts { print("  \(script)") }
            }
            if let commands = trust["agentCommands"] as? [String], !commands.isEmpty {
                print("Agent commands:")
                for command in commands { print("  \(command)") }
            }
        }
        let workspaces = plan["workspaces"] as? [[String: Any]] ?? []
        print("Workspaces (\(workspaces.count)):")
        for (index, workspace) in workspaces.enumerated() {
            let title = workspace["title"] as? String ?? ""
            let directory = workspace["directory"] as? String ?? ""
            let branch = (workspace["branch"] as? String).map { " [\($0)]" } ?? ""
            print("  \(index + 1). \(title) -> \(directory)\(branch)")
        }
        for note in plan["notes"] as? [String] ?? [] {
            print("note: \(note)")
        }
        print("Trust confirmed: \(trustConfirmed ? "yes" : "no")")
    }
}
