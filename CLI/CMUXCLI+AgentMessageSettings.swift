import Foundation

/// `cmux agent messages [on|off|status] [<target>] [--workspace]`: turns agent
/// messages off or on for one surface or workspace through
/// `agent.message.settings`. The app-wide switch is `agentMessages.enabled`.
extension CMUXCLI {
    static var agentMessagesHelp: String {
        String(localized: "cli.help.agentMessages", defaultValue: """
        Usage: cmux agent messages [on|off|status] [<target>] [--workspace] [--json]

        Turn agent messages off or on for one agent, or show whether it gets
        them. Turning messages off for an agent refuses new messages to it and
        marks the ones already queued for it as failed.

        <target> is resolved like cmux agent message: a workspace or surface id
        or ref, or a workspace title. Without one, the command applies to the
        surface it runs in. --workspace applies to every surface in the
        workspace instead.

        Without --workspace, a workspace target means the one agent surface it
        resolves to now. That surface stays off even if a different surface
        becomes the workspace's agent later.

        To turn agent messages off everywhere, set agentMessages.enabled to
        false in ~/.config/cmux/cmux.json or turn off Settings > Automation >
        Agent Messages.

        Examples:
          cmux agent messages off
          cmux agent messages on workspace:3
          cmux agent messages off --workspace cmux-remote-status
        """)
    }

    /// Per-verb help for `cmux agent <verb> --help`, or `nil` for verbs that
    /// use the `cmux agent` family text.
    static func agentSubcommandHelp(_ verb: String?) -> String? {
        switch verb?.lowercased() {
        case "message", "msg": return agentMessageHelp
        case "inbox": return agentInboxHelp
        case "messages": return agentMessagesHelp
        default: return nil
        }
    }

    /// Parsed `cmux agent messages` arguments.
    struct AgentMessagesSettingArguments: Equatable {
        /// `nil` reads the current setting.
        var enabled: Bool?
        var target: String?
        var workspace: Bool
    }

    static func parseAgentMessagesSettingArguments(_ args: [String]) throws -> AgentMessagesSettingArguments {
        var parsed = AgentMessagesSettingArguments(enabled: nil, target: nil, workspace: false)
        var words: [String] = []
        for arg in args {
            switch arg {
            case "--json": continue
            case "--workspace": parsed.workspace = true
            default:
                guard !arg.hasPrefix("--") else { throw CLIError(message: agentMessagesHelp) }
                words.append(arg)
            }
        }
        if let verb = words.first?.lowercased(), ["on", "off", "status"].contains(verb) {
            parsed.enabled = verb == "status" ? nil : verb == "on"
            words.removeFirst()
        }
        guard words.count <= 1 else { throw CLIError(message: agentMessagesHelp) }
        parsed.target = words.first
        return parsed
    }

    func runAgentMessagesSetting(_ args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let parsed = try Self.parseAgentMessagesSettingArguments(args)
        var params: [String: Any] = ["scope": parsed.workspace ? "workspace" : "surface"]
        if let enabled = parsed.enabled { params["enabled"] = enabled }
        if let target = parsed.target { params["target"] = target }
        let env = ProcessInfo.processInfo.environment
        if let surface = env["CMUX_SURFACE_ID"], !surface.isEmpty { params["surface_id"] = surface }
        if let workspace = env["CMUX_WORKSPACE_ID"], !workspace.isEmpty { params["workspace_id"] = workspace }

        let payload = try client.sendV2(method: "agent.message.settings", params: params)
        if jsonOutput {
            print(jsonString(payload))
            return
        }
        let ref = payload["ref"] as? String ?? "?"
        let title = payload["workspace_title"] as? String ?? ""
        let label = title.isEmpty ? ref : "\(ref) (\(title))"
        let format = payload["receiving"] as? Bool == false
            ? String(localized: "cli.agentMessages.off", defaultValue: "Messages to %@ are off.")
            : String(localized: "cli.agentMessages.on", defaultValue: "Messages to %@ are on.")
        print(String(format: format, label))
        if payload["workspace_receiving"] as? Bool == false {
            print(String(
                localized: "cli.agentMessages.workspaceOff",
                defaultValue: "Its workspace has messages off, so it receives none."
            ))
        }
        if payload["messages_enabled"] as? Bool == false {
            print(String(
                localized: "cli.agentMessages.globalOff",
                defaultValue: "Agent messages are turned off for all of cmux (agentMessages.enabled is false)."
            ))
        }
    }
}
