import Foundation

/// `cmux vm self <machine> [<path>]` — a machine's identity as the platform sees it,
/// read from the Mac. Inside a machine the same facts come from `cmux self`; both are
/// the reflection document (services/vms/reflection.ts), so an agent on either side of
/// the link sees one truth: name, status, owner, team, plan, network, peers, and the
/// integrations the machine can use. Nothing runs on the machine to answer.
extension CMUXCLI {
    static let vmSelfUsage = """
        Usage: cmux vm self <machine> [<path>] [--json]

        Who a machine is, as the platform sees it — the same reflection a process inside
        it reads with `cmux self`, fetched through your signed-in session (no shell is
        started on the machine, and a sleeping machine stays asleep).

          <path>   owner | machine | peers | integrations (any reflection path).
                   Without one: the index — name, status, owner, team, plan, paths.
          --json   Print the raw reflection body.

        Examples:
          cmux vm self brave-otter
          cmux vm self brave-otter peers
          cmux vm self brave-otter integrations --json
        """

    func runVMSelfCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        if rest.contains("--help") || rest.contains("-h") {
            print(Self.vmSelfUsage)
            return
        }
        let args = rest.filter { $0 != "--json" }
        if let unknown = args.first(where: { $0.hasPrefix("-") }) {
            throw CLIError(message: "Unknown option \(unknown)\n\n\(Self.vmSelfUsage)")
        }
        guard (1...2).contains(args.count) else {
            throw CLIError(message: Self.vmSelfUsage)
        }
        let machine = args[0]
        let path = args.count == 2 ? args[1].trimmingCharacters(in: CharacterSet(charactersIn: "/")) : ""
        let response = try client.sendV2(
            method: "vm.reflection",
            params: ["id": machine, "path": path],
            responseTimeout: 70
        )
        let body = (response["reflection"] as? [String: Any]) ?? [:]
        let status = (response["http_status"] as? Int) ?? 200
        if status == 404 {
            if jsonOutput { print(jsonString(body)) }
            guard !path.isEmpty else {
                throw CLIError(message: "\(machine) has no reflection index")
            }
            let paths = Self.vmReflectionPaths(body)
            let hint = paths.isEmpty ? "" : " Paths: \(paths.joined(separator: ", "))"
            throw CLIError(message: "\(machine) has no reflection path '\(path)'.\(hint)")
        }
        guard (200...299).contains(status) else {
            if jsonOutput || !path.isEmpty { print(jsonString(body)) }
            throw CLIError(message: "\(machine) reflection request failed (HTTP \(status))")
        }
        if jsonOutput || !path.isEmpty {
            print(jsonString(body))
            return
        }
        for line in Self.vmReflectionIndexLines(body) {
            print(line)
        }
    }

    /// The `paths` list of a reflection index (or a 404 body): `[{path, description}]`
    /// or bare strings, as path strings.
    static func vmReflectionPaths(_ body: [String: Any]) -> [String] {
        ((body["paths"] as? [Any]) ?? []).compactMap { item in
            if let entry = item as? [String: Any] { return entry["path"] as? String }
            return item as? String
        }
    }

    /// The human form of the index: tab-separated lines, the same shape `cmux self`
    /// prints inside a machine, so eyes and scripts (`cut -f2`) read both alike.
    static func vmReflectionIndexLines(_ body: [String: Any]) -> [String] {
        var lines: [String] = []
        let name = (body["name"] as? String) ?? (body["display_name"] as? String) ?? "?"
        lines.append("name\t\(name)")
        let vmID = (body["vm_id"] as? String) ?? (body["id"] as? String) ?? "?"
        let status = (body["status"] as? String) ?? "?"
        lines.append("machine\t\(vmID)\t\(status)")
        let owner = body["owner"] as? [String: Any]
        let ownerLabel = (owner?["email"] as? String)
            ?? (owner?["user_id"] as? String)
            ?? (owner?["display_name"] as? String)
            ?? "?"
        lines.append("owner\t\(ownerLabel)")
        let teamID = (body["team_id"] as? String)
            ?? ((body["team"] as? [String: Any])?["id"] as? String)
            ?? "-"
        var teamLine = "team\t\(teamID)"
        if let machines = body["machines"] as? [Any] {
            teamLine += "\t\(machines.count) machine\(machines.count == 1 ? "" : "s")"
        }
        lines.append(teamLine)
        if let plan = body["plan_id"] as? String, !plan.isEmpty {
            lines.append("plan\t\(plan)")
        }
        let paths = vmReflectionPaths(body)
        if !paths.isEmpty {
            lines.append("paths\t\(paths.joined(separator: ", "))")
        }
        return lines
    }
}
