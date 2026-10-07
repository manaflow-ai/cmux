/// What the native sheet asks the user to confirm (R2, P2).
public nonisolated enum AgentPaneModeConfirmation: Equatable, Sendable, CustomStringConvertible {
    /// session/set_mode, or set_config_option of the `mode` option, to this mode id.
    case mode(String)
    /// set_config_option of another option that is not free, to this value (as text).
    case option(id: String, value: String)

    /// For logs and tests: the mode, or `id = value`.
    public var description: String {
        switch self {
        case .mode(let mode): mode
        case .option(let id, let value): "\(id) = \(value)"
        }
    }
}
