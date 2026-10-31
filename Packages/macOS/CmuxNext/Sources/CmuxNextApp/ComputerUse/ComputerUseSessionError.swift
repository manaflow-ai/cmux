/// Why the CUA host could not answer.
nonisolated enum ComputerUseSessionError: Error, Equatable, Sendable {
    /// No helper runs; the reason says why (off, turned off by policy, not installed).
    case notRunning(String)
    /// The host refused or did not answer; the reason is shown as is.
    case failed(String)

    var reason: String {
        switch self {
        case .notRunning(let reason), .failed(let reason): reason
        }
    }
}
