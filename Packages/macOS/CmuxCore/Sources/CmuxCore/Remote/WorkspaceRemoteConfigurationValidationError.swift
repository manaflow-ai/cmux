/// A failure assembling a ``WorkspaceRemoteConfiguration`` from control-plane
/// parameters.
///
/// Every case carries the exact wire ``message`` returned to a
/// `workspace.remote.configure` caller. The ``code`` is always
/// `"invalid_params"`, matching the original app-target command body.
public enum WorkspaceRemoteConfigurationValidationError: Error, Equatable, Sendable {
    /// A parameter failed a range, format, or coupling rule. The associated
    /// value is the user-facing message returned verbatim to the caller.
    case invalidParameter(String)

    /// The error code returned to the caller (always `"invalid_params"`).
    public var code: String { "invalid_params" }

    /// The user-facing message returned verbatim to the caller.
    public var message: String {
        switch self {
        case .invalidParameter(let message):
            return message
        }
    }
}
