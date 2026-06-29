public import Foundation

/// Builds cmux auth callback URLs for a resolved web origin.
public struct AuthCallbackURLResolver: Sendable {
    private let origin: URL

    /// Creates a resolver rooted at the cmux web origin for the active auth environment.
    public init(origin: URL) {
        self.origin = origin
    }

    /// The Stack magic-link callback endpoint accepted by the cmux web app.
    public func magicLinkCallbackURL() -> URL {
        origin.appendingPathComponent("handler/magic-link-callback", isDirectory: false)
    }
}
