/// The setting a frame asks for, as the Rust policy's facts name it (R2, P2). Only a config option
/// that is not free asks the user on a native sheet; a mode needs no sheet (Lawrence 2026-10-07,
/// "Remove dialogues."): the user's gesture is the consent.
public nonisolated enum AgentPaneModeConfirmation: Equatable, Sendable, CustomStringConvertible {
    /// session/set_mode, or set_config_option of the `mode` option, to this mode id.
    case mode(String)
    /// set_config_option of another option that is not free, to this value (as text).
    case option(id: String, value: String)

    /// Whether the user confirms it on the native sheet: an option, never a mode.
    public var needsSheet: Bool {
        if case .option = self { true } else { false }
    }

    /// For logs and tests: the mode, or `id = value`.
    public var description: String {
        switch self {
        case .mode(let mode): mode
        case .option(let id, let value): "\(id) = \(value)"
        }
    }
}
