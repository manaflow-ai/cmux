import Foundation

/// Supplies bearer access tokens and authentication state to the mobile API transport.
///
/// This is the auth seam the mobile contract depends on. The mobile transport, push client,
/// analytics client, and mark-read client all reach for an access token and an authentication
/// flag through this protocol instead of reaching up into a concrete auth manager. The app's
/// auth manager conforms to it at the composition root.
///
/// ```swift
/// extension AuthManager: AuthTokenProviding {
///     func accessToken() async throws -> String { try await getAccessToken() }
/// }
/// ```
@MainActor
public protocol AuthTokenProviding: AnyObject {
    /// Whether a user is currently authenticated, read synchronously for fast guards.
    var isAuthenticated: Bool { get }

    /// Returns a fresh bearer access token, refreshing or signing in as needed.
    ///
    /// - Returns: A non-empty bearer token suitable for an `Authorization: Bearer …` header.
    /// - Throws: An error when no token can be obtained (for example, the user is signed out).
    func accessToken() async throws -> String
}
