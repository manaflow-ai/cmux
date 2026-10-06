import Foundation

/// `cmux agent compact-resume`: compacts the context of the Claude Code or
/// Codex session in a pane and continues it. Defaults to the caller's own
/// pane, so an agent can run it on itself.
extension CMUXCLI {
    static let agentCompactResumeUsage = String(
        localized: "cli.agent.compactResume.usage",
        defaultValue: """
        Usage: cmux agent compact-resume [--surface <id>] [--focus <text>] [--when idle|now] [--json]

        Compact the context of the Claude Code or Codex session in a terminal pane,
        then continue where it left off. The focus note defaults to the session's
        last prompt; --focus replaces it.

        Options:
          --surface <id>   Terminal pane (default: this pane, $CMUX_SURFACE_ID)
          --focus <text>   What the compacted summary should keep
          --when idle      Wait for the running turn to end (default)
          --when now       Interrupt the running turn first

        Nothing is typed while the agent is asking a question or while its input
        has text in it. The command returns once the run has started.
        """
    )

    func runAgentCompactResume(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        if hasHelpRequest(beforeSeparator: commandArgs) {
            print(Self.agentCompactResumeUsage)
            return
        }
        let (surfaceArg, rem0) = parseOption(commandArgs, name: "--surface")
        let (focus, rem1) = parseOption(rem0, name: "--focus")
        let (when, rem2) = parseOption(rem1, name: "--when")
        if let unexpected = rem2.first {
            let message = String(
                localized: "cli.agent.compactResume.error.unexpected",
                defaultValue: "agent compact-resume: unexpected argument"
            )
            throw CLIError(message: "\(message) \(unexpected)")
        }
        let surfaceRaw = surfaceArg ?? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]
        guard let surfaceID = try normalizeSurfaceHandle(surfaceRaw, client: client) else {
            throw CLIError(message: String(
                localized: "cli.agent.compactResume.error.surfaceRequired",
                defaultValue: "agent compact-resume needs --surface <id> outside a cmux terminal"
            ))
        }
        var params: [String: Any] = ["surface_id": surfaceID]
        if let focus { params["focus"] = focus }
        if let when { params["when"] = when.lowercased() }
        let payload = try client.sendV2(method: "agent.compact_resume", params: params)
        if jsonOutput {
            print(jsonString(payload))
        } else {
            print(String(
                localized: "cli.agent.compactResume.started",
                defaultValue: "Compact and resume started."
            ))
        }
    }
}
