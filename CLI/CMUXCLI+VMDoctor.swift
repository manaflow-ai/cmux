import Foundation

// MARK: - `cmux vm doctor`: agent readiness on a machine

extension CMUXCLI {
    static let vmDoctorAgentNames = ["claude", "codex", "opencode", "pi", "gh", "git"]

    static let vmDoctorUsage = """
    Usage: cmux vm doctor <machine> [--agent <claude|codex|opencode|pi|gh>] [--probe] [--json]

    Check whether each coding agent on a machine can start: is it installed, which
    credential its next launch uses (a key from Cloud Secrets or the machine env,
    its own sign-in, cmux model routing, or none), and where that credential goes
    (the provider's own endpoint, cmux model routing, or an endpoint of yours).
    One Fix: line follows every problem.

    The check runs one names-only script on the machine: no secret value is in its
    command, its output, or anything printed here.

    Options:
      --agent <name>   Check one agent (git is the gh row).
      --probe          Also send each key to its own provider in one minimal,
                       no-cost request (a models or rate-limit listing) and report
                       the HTTP status. A key bound for cmux model routing or for an
                       endpoint of your own is never sent.
      --json           Print {machine, supported, probe, checked_at, agents: [{agent,
                       name, installed, version, source, key, credential, endpoint,
                       endpoint_kind, host, probe: {result, status}, status, detail,
                       fix}], problems, attention}.

    Exits 1 when an agent needs a fix. `cmux vm agent` and `vm clone --agent` run the
    quick form (no network) before they start an agent and print one warning line.

    Examples:
      cmux vm doctor brave-otter
      cmux vm doctor brave-otter --agent codex --probe
    """

    func runVMDoctorCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        if rest.contains("--help") || rest.contains("-h") {
            print(Self.vmDoctorUsage)
            return
        }
        var machine: String?
        var agent: String?
        var probe = false
        var json = jsonOutput
        var index = 0
        while index < rest.count {
            let arg = rest[index]
            switch arg {
            case "--agent":
                guard index + 1 < rest.count else {
                    throw CLIError(message: "--agent requires a value\n\n\(Self.vmDoctorUsage)")
                }
                index += 1
                agent = rest[index].lowercased()
            case "--probe":
                probe = true
            case "--json":
                json = true
            default:
                guard !arg.hasPrefix("-"), machine == nil else {
                    throw CLIError(message: "vm doctor: unknown option \(arg)\n\n\(Self.vmDoctorUsage)")
                }
                machine = arg
            }
            index += 1
        }
        guard let machine else {
            throw CLIError(message: Self.vmDoctorUsage)
        }
        if let agent, !Self.vmDoctorAgentNames.contains(agent) {
            throw CLIError(message: "vm doctor: --agent must be one of \(Self.vmDoctorAgentNames.joined(separator: ", "))\n\n\(Self.vmDoctorUsage)")
        }
        let display = Self.vmMachineDisplayName(machine)
        var params: [String: Any] = ["id": machine, "probe": probe, "machine_label": display]
        if let agent { params["agent"] = agent }
        let response: [String: Any]
        do {
            response = try client.sendV2(method: "vm.agent_readiness", params: params, responseTimeout: probe ? 90 : 45)
        } catch let error as CLIError where error.v2Code == "method_not_found" {
            throw CLIError(message: String(
                localized: "cli.vm.doctor.unsupportedApp",
                defaultValue: "vm doctor: this cmux app cannot check agents yet. Update cmux and try again."
            ))
        }
        let problems = (response["problems"] as? Int) ?? 0
        if json {
            print(jsonString(response))
        } else {
            guard response["supported"] as? Bool == true else {
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.vm.doctor.unsupportedMachine",
                        defaultValue: "vm doctor: %1$@ did not answer the check. Make sure it is running (cmux vm wait %1$@ --wake) and try again."
                    ),
                    display
                ))
            }
            let agents = (response["agents"] as? [[String: Any]]) ?? []
            print(Self.vmDoctorReport(agents: agents, machine: display, probed: probe))
        }
        if problems == 1 {
            throw CLIError(message: String(
                format: String(localized: "cli.vm.doctor.problem", defaultValue: "vm doctor: 1 agent on %@ needs a fix."),
                display
            ))
        } else if problems > 1 {
            throw CLIError(message: String(
                format: String(localized: "cli.vm.doctor.problems", defaultValue: "vm doctor: %1$ld agents on %2$@ need a fix."),
                problems, display
            ))
        }
    }

    /// The table, one Fix: line per row that needs one, and a summary.
    static func vmDoctorReport(agents: [[String: Any]], machine: String, probed: Bool) -> String {
        let header = [
            String(localized: "cli.vm.doctor.column.agent", defaultValue: "AGENT"),
            String(localized: "cli.vm.doctor.column.credential", defaultValue: "CREDENTIAL"),
            String(localized: "cli.vm.doctor.column.endpoint", defaultValue: "ENDPOINT"),
            String(localized: "cli.vm.doctor.column.status", defaultValue: "STATUS"),
        ]
        let rows = agents.map { agent -> [String] in
            [
                (agent["name"] as? String) ?? (agent["agent"] as? String) ?? "?",
                (agent["credential"] as? String) ?? "?",
                (agent["endpoint"] as? String) ?? "?",
                (agent["status_label"] as? String) ?? (agent["status"] as? String) ?? "?",
            ]
        }
        var lines = [vmDoctorColumns(header: header, rows: rows)]
        var notes: [String] = []
        for agent in agents {
            let status = (agent["status"] as? String) ?? ""
            guard status != "ready" else { continue }
            let name = (agent["name"] as? String) ?? (agent["agent"] as? String) ?? "?"
            if let detail = agent["detail"] as? String, !detail.isEmpty {
                notes.append("\(name): \(detail)")
            }
            if let fix = agent["fix"] as? String, !fix.isEmpty {
                notes.append(String(format: String(localized: "cli.vm.doctor.fix", defaultValue: "  Fix: %@"), fix))
            }
        }
        if !notes.isEmpty {
            lines.append("")
            lines.append(contentsOf: notes)
        }
        let ready = agents.filter { ($0["status"] as? String) == "ready" }.count
        lines.append("")
        lines.append(String(
            format: String(localized: "cli.vm.doctor.summary", defaultValue: "%1$@: %2$ld of %3$ld ready."),
            machine, ready, agents.count
        ))
        if !probed, agents.contains(where: { ($0["source"] as? String) == "key" }) {
            lines.append(String(
                format: String(localized: "cli.vm.doctor.probeHint", defaultValue: "Test each key with its provider: cmux vm doctor %@ --probe"),
                machine
            ))
        }
        return lines.joined(separator: "\n")
    }

    private static func vmDoctorColumns(header: [String], rows: [[String]]) -> String {
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        return all.map { row in
            row.indices.map { column in
                column == row.count - 1 ? row[column] : row[column].padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }
            .joined(separator: "  ")
        }
        .joined(separator: "\n")
    }

    // MARK: - Before an agent starts

    /// The pre-launch budget: the check never holds an agent back longer than this.
    static let vmAgentReadinessPreLaunchTimeout: TimeInterval = 5

    /// `vm agent` / `vm clone --agent`: the quick readiness check (no network on the
    /// machine) for the agent about to start, printing one warning line when it has
    /// no usable credential or would send a key where it does not belong. Never
    /// blocks and never fails: an older app or machine, a timeout, or any error is
    /// silence.
    func warnIfVMAgentNotReady(machine: String, agent: String, client: SocketClient) {
        let params: [String: Any] = [
            "id": machine,
            "agent": agent,
            "fast": true,
            "machine_label": Self.vmMachineDisplayName(machine),
        ]
        guard let response = try? client.sendV2(
            method: "vm.agent_readiness",
            params: params,
            responseTimeout: Self.vmAgentReadinessPreLaunchTimeout
        ), response["supported"] as? Bool == true,
            let agents = response["agents"] as? [[String: Any]] else { return }
        for entry in agents where (entry["agent"] as? String) == agent {
            if let warning = entry["warning"] as? String, !warning.isEmpty {
                cliWriteStderr(warning + "\n")
            }
        }
    }
}
