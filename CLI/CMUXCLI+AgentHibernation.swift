import Foundation

extension CMUXCLI {
    static var agentHibernationUsage: String {
        String(
            localized: "cli.agentHibernation.usage",
            defaultValue: "Usage: cmux agent-hibernation <on|off> [--json]\n       cmux agent-hibernation <hibernate|wake> <surface> [--workspace <id|ref|index>] [--json]"
        )
    }

    /// `hibernate <surface>` and `wake <surface>`. The app runs every safety
    /// check and reports why it refused, so the CLI only resolves the target.
    func runAgentHibernationTarget(
        subcommand: String,
        args: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let (workspaceRaw, afterWorkspace) = parseOption(args, name: "--workspace")
        let (surfaceOption, remaining) = parseOption(afterWorkspace, name: "--surface")
        let positional = remaining.filter { !$0.hasPrefix("-") }
        guard let surfaceRaw = surfaceOption ?? positional.first,
              !surfaceRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              positional.count <= (surfaceOption == nil ? 1 : 0) else {
            throw CLIError(message: Self.agentHibernationUsage)
        }

        var params: [String: Any] = [:]
        let workspaceId = try normalizeWorkspaceHandle(workspaceRaw, client: client)
        if let workspaceId { params["workspace_id"] = workspaceId }
        guard let surfaceId = try normalizeSurfaceHandle(
            surfaceRaw,
            client: client,
            workspaceHandle: workspaceId
        ) else {
            throw CLIError(message: Self.agentHibernationUsage)
        }
        params["surface_id"] = surfaceId

        let isWake = subcommand == "wake"
        // Hibernation waits for the transcript snapshot and the agent's exit.
        let response = try client.sendV2(
            method: isWake ? "agent.wake" : "agent.hibernate",
            params: params,
            responseTimeout: isWake ? 30 : 120
        )
        if jsonOutput {
            print(jsonString(response))
            return
        }
        let format = isWake
            ? String(localized: "cli.agentHibernation.woke", defaultValue: "OK woke %@")
            : String(localized: "cli.agentHibernation.hibernated", defaultValue: "OK hibernated %@")
        print(String(format: format, surfaceRaw))
    }
}
