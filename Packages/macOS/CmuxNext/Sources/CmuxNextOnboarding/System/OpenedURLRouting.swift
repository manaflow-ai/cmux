public import Foundation

/// Where `AppDelegate` sends a URL macOS hands cmux: the sign-in callback
/// goes to Cloud auth first (`<scheme>://auth-callback` and the path forms
/// auth accepts), so it never reaches `link.open`; everything else goes to
/// `ExternalOpenController`, which refuses what it does not open.
public struct OpenedURLRouting {
    public enum Destination: Equatable, Sendable {
        /// Cloud auth's `handleCallback`.
        case auth
        /// `ExternalOpenController` opened it (a tab, or `link.open`).
        case opened
        /// Nothing cmux opens.
        case ignored
    }

    private let isAuthCallback: (URL) -> Bool
    private let open: (URL) -> Bool

    public init(isAuthCallback: @escaping (URL) -> Bool, open: @escaping (URL) -> Bool) {
        self.isAuthCallback = isAuthCallback
        self.open = open
    }

    public func route(_ url: URL) -> Destination {
        if isAuthCallback(url) { return .auth }
        return open(url) ? .opened : .ignored
    }
}
