/// A CLI family identified by an owner's checked executable or package evidence.
public nonisolated enum AgentCLIFamily: String, Decodable, Sendable, Equatable {
    /// Claude Code.
    case claude
    /// The Codex CLI, including compatible installations under its executable name.
    case codex
    /// OpenCode.
    case opencode
    /// Pi.
    case pi
    /// Chief.
    case chief
    /// Gemini CLI.
    case gemini
    /// Amp.
    case amp
    /// Copilot CLI.
    case copilot
    /// Cursor Agent.
    case cursor
    /// An unrecognized future family; never a substitute for a profile name.
    case unknown

    /// Decodes known family IDs, preserving future string values as unknown.
    /// - Parameter decoder: A decoder for one owner's family identifier.
    /// - Throws: A decoding error for non-string values.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}
