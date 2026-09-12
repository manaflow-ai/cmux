import Foundation

extension BrokerCredentialClient {
    /// One coherent token pair from an already signed-in Stack session.
    public struct SessionTokens: Sendable {
        /// Access credential for the signed-in account; never log its contents.
        public let accessToken: String
        /// Refresh credential from the same session; never log its contents.
        public let refreshToken: String

        /// Captures both credentials from one authoritative session snapshot.
        ///
        /// - Parameters:
        ///   - accessToken: Current account access credential.
        ///   - refreshToken: Refresh credential belonging to the same account session.
        public init(accessToken: String, refreshToken: String) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
        }
    }
}
