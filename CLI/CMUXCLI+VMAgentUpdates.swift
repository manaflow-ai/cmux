import Foundation

// MARK: - `cmux vm agent-updates`

extension CMUXCLI {
    static var vmAgentUpdatesUsage: String {
        String(
            localized: "cli.vm.agentUpdates.usage",
            defaultValue: "Usage:\n  cmux vm agent-updates <id>                 Show the machine's setting.\n  cmux vm agent-updates <id> <latest|image>  Change it.\n\nlatest updates Claude Code, Codex, OpenCode, and Pi to the newest npm\nrelease when you connect, at most once a day. image keeps the versions the\nmachine's image baked (the default). Updates need registry.npmjs.org: with\nnetwork mode none, or an allowlist without the npm preset, they fail. Add\n--json for the structured result."
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

    /// The note `vm new` prints when `latest` meets a network policy that
    /// blocks the npm registry. Mirrors `CloudNetworkPolicy.allowsNpmRegistry`
    /// on the raw JSON the CLI holds (the CLI does not link CmuxCloud).
    static func vmAgentUpdatesNetworkNote(setting: String, policy: [String: Any]?) -> String? {
        guard setting == "latest", let policy, let mode = policy["mode"] as? String else { return nil }
        let presets = policy["presets"] as? [String] ?? []
        let domains = policy["domains"] as? [String] ?? []
        let blocked: Bool
        switch mode {
        case "none": blocked = true
        case "allowlist": blocked = !presets.contains("npm") && !domains.contains("registry.npmjs.org")
        default: blocked = false
        }
        guard blocked else { return nil }
        return String(
            localized: "cloud.agentUpdates.npmBlocked",
            defaultValue: "Updates need npm registry access. Add the npm preset or they will fail."
        )
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
