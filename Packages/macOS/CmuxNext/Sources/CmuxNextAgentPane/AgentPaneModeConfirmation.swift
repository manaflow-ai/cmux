/// What the native sheet asks the user to confirm (P2): a config option that is not free. A mode
/// needs no sheet (Lawrence 2026-10-07, "Remove dialogues."): the user's gesture is the consent.
public nonisolated enum AgentPaneModeConfirmation: Equatable, Sendable, CustomStringConvertible {
    /// set_config_option of an option other than `mode` that is not free, to this value (as text).
    case option(id: String, value: String)

    /// For logs and tests: `id = value`.
    public var description: String {
        switch self {
        case .option(let id, let value): "\(id) = \(value)"
        }
    }
}
