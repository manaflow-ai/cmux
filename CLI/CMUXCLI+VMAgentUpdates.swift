import Foundation

// MARK: - `cmux vm agent-updates`

extension CMUXCLI {
    static var vmAgentUpdatesUsage: String {
        String(
            localized: "cli.vm.agentUpdates.usage",
            defaultValue: "Usage:\n  cmux vm agent-updates <id>                 Show the machine's setting.\n  cmux vm agent-updates <id> <latest|image>  Change it.\n\nlatest updates Claude Code, Codex, OpenCode, Pi, and agent-browser to each\ntool's newest GitHub release when you connect, at most once a day, checked\nagainst its sha256 digest. image keeps the versions the machine's image\nbaked (the default). Updates reach only GitHub, which every network mode\nallows. Add --json for the structured result.\nA new release installs only after it has been public for 3 days."
        )
    }

    private static let vmAgentUpdatesSettings: Set<String> = ["latest", "image"]

    /// `latest` or `image`, for `vm new --agent-updates` and `vm agent-updates`.
    static func parseVMAgentUpdatesSetting(_ raw: String, command: String) throws -> String {
        let setting = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard vmAgentUpdatesSettings.contains(setting) else {
            let format = String(
                localized: "cli.vm.agentUpdates.invalid",
                defaultValue: "%@: agent updates must be latest or image."
            )
            throw CLIError(message: String(format: format, command))
        }
        return setting
    }

    /// Reads go to `vm.agent_updates_get`; a value goes to `vm.agent_updates_set`,
    /// the same path the machine menu's "Keep Agents Up to Date" uses.
    func runVMAgentUpdatesCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        if rest.contains("--help") || rest.contains("-h") {
            print(Self.vmAgentUpdatesUsage)
            return
        }
        let json = jsonOutput || rest.contains("--json")
        let args = rest.filter { $0 != "--json" }
        guard let vmId = args.first, !vmId.hasPrefix("-"), args.count <= 2 else {
            throw CLIError(message: Self.vmAgentUpdatesUsage)
        }
        let response: [String: Any]
        if let raw = args.dropFirst().first {
            let setting = try Self.parseVMAgentUpdatesSetting(raw, command: "vm agent-updates")
            response = try client.sendV2(
                method: "vm.agent_updates_set",
                params: ["id": vmId, "agent_updates": setting],
                responseTimeout: 60
            )
        } else {
            response = try client.sendV2(method: "vm.agent_updates_get", params: ["id": vmId], responseTimeout: 60)
        }
        if json {
            print(jsonString(response))
            return
        }
        print("\(vmId)  agent-updates=\(response["agent_updates"] as? String ?? "image")")
        if let note = response["note"] as? String, !note.isEmpty {
            FileHandle.standardError.write(Data("\(note)\n".utf8))
        }
    }
}
