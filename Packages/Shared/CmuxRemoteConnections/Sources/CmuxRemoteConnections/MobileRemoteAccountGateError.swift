/// Failures from the account prerequisite for every remote connection.
public enum MobileRemoteAccountGateError: Error, Equatable, Sendable {
    /// No authenticated cmux account is currently available.
    case authenticationRequired
    /// The auth coordinator supplied an invalid account identifier.
    case invalidAccount
}
