/// Failures from the bundled Subrouter process boundary.
enum SubrouterAccountServiceError: Error, Sendable {
    case executableUnavailable
    case launchFailed(String)
    case commandFailed(arguments: [String], status: Int32, message: String)
    case malformedAccount(String)
}
