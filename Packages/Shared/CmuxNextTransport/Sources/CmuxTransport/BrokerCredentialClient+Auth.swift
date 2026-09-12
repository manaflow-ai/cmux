import Foundation

extension BrokerCredentialClient {
    /// Account authentication for the environment-based entry point. Both
    /// modes delegate to the same broker flow the legacy `Config` and
    /// `SessionConfig` initializers drive.
    public enum Auth: Sendable {
        /// Dev harnesses: mint a fresh Stack session from a password pair.
        case password(email: String, password: String)
        /// Production shape: the app's already signed-in Stack session
        /// supplies the CURRENT pair per mint; nil fails closed
        /// (`BrokerError.notSignedIn`), never minting as a guessed account.
        case session(tokens: @Sendable () async throws -> SessionTokens?)
    }
}
