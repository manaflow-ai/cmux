/// Describes one agent command intercepted by the shared per-surface shim path.
struct TerminalSurfaceAgentCommandShimDefinition: Sendable {
    let commandName: String
    let wrapperName: String
    let environmentVariablePrefix: String

    /// The single capability table for cmux-managed agent launch wrappers.
    static let bundled: [Self] = [
        Self(
            commandName: "claude",
            wrapperName: "cmux-claude-wrapper",
            environmentVariablePrefix: "CMUX_CLAUDE"
        ),
        Self(
            commandName: "codex",
            wrapperName: "cmux-codex-wrapper",
            environmentVariablePrefix: "CMUX_CODEX"
        ),
        Self(
            commandName: "hermes",
            wrapperName: "cmux-hermes-agent-wrapper",
            environmentVariablePrefix: "CMUX_HERMES_AGENT"
        ),
    ]
}
