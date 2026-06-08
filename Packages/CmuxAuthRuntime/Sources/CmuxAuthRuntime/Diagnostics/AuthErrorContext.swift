import Foundation

/// Structured, non-sensitive context attached to a captured auth failure.
///
/// The conforming reporter (which owns the backend SDK) is responsible for
/// extracting any stable error code from the reported error itself; this
/// context only carries the flow-level facts the coordinator knows.
public struct AuthErrorContext: Sendable, Equatable {
    /// The auth flow that failed (e.g. `"oauth"`, `"password"`, `"magic_link"`).
    public let flow: String
    /// The OAuth provider when ``flow`` is `"oauth"` (e.g. `"apple"`), else `nil`.
    public let provider: String?

    /// Creates an auth error context.
    /// - Parameters:
    ///   - flow: The failing auth flow.
    ///   - provider: The OAuth provider, when applicable.
    public init(flow: String, provider: String? = nil) {
        self.flow = flow
        self.provider = provider
    }
}
