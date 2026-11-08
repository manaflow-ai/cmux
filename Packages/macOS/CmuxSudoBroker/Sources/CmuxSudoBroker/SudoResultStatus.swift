/// The terminal status of a sudo request.
public enum SudoResultStatus: String, Codable, Sendable, Equatable {
    /// The approved script exited and supplied an exit status.
    case completed

    /// The user denied the request.
    case denied

    /// The broker could not execute or finish the request safely.
    case failed
}
