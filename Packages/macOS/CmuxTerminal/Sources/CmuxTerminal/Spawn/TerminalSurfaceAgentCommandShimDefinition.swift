/// Agent commands that cmux can intercept with a per-surface launch shim.
public enum TerminalSurfaceAgentCommand: String, CaseIterable, Hashable, Sendable {
    case claude
    case codex
    case amp
    case hermes
}

/// Describes one agent command intercepted by the shared per-surface shim path.
struct TerminalSurfaceAgentCommandShimDefinition: Sendable {
    let command: TerminalSurfaceAgentCommand
    let wrapperName: String
    let environmentVariablePrefix: String

    var commandName: String { command.rawValue }

    /// The single capability table for cmux-managed agent launch wrappers.
    static let bundled: [Self] = [
        Self(
            command: .claude,
            wrapperName: "cmux-claude-wrapper",
            environmentVariablePrefix: "CMUX_CLAUDE"
        ),
        Self(
            command: .codex,
            wrapperName: "cmux-codex-wrapper",
            environmentVariablePrefix: "CMUX_CODEX"
        ),
        Self(
            command: .amp,
            wrapperName: "cmux-amp-wrapper",
            environmentVariablePrefix: "CMUX_AMP"
        ),
        Self(
            command: .hermes,
            wrapperName: "cmux-hermes-agent-wrapper",
            environmentVariablePrefix: "CMUX_HERMES_AGENT"
        ),
    ]
}
