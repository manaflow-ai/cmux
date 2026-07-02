public import Foundation

/// Redacted authentication state included in a mobile diagnostics report.
public struct MobileDiagnosticsAuthState: Sendable, Equatable {
    /// Whether the app currently considers the user signed in.
    public var isSignedIn: Bool
    /// The most recent display-safe auth error class, if one has been recorded.
    public var lastError: String?

    /// Create a redacted auth-state snapshot.
    ///
    /// - Parameters:
    ///   - isSignedIn: Whether the app currently considers the user signed in.
    ///   - lastError: The most recent display-safe auth error class.
    public init(isSignedIn: Bool, lastError: String? = nil) {
        self.isSignedIn = isSignedIn
        self.lastError = lastError
    }
}
