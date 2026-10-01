/// Errors a backend adapter reports in the GUI's terms.
public enum ConversationBackendError: Error, Hashable, Sendable {
    /// The host could not be reached or the connection dropped.
    case unreachable(String)
    /// The backend answered with an error.
    case refused(code: Int, message: String)
    /// No response within the deadline.
    case timedOut
    /// The backend lacks a feature this call needs; the host needs an update.
    case unsupported(String)
    /// The backend sent something this client cannot read.
    case protocolViolation(String)
}
