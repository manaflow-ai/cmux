public import Foundation

/// A background website notification click reduced to the display origin that
/// may be opened when its service-worker click handler is unavailable.
public struct NotificationNavWebsiteClickTarget: Sendable, Equatable {
    /// The user-facing HTTP(S) origin used only for external-open fallback.
    public let displayOrigin: URL

    /// Creates a background website notification click target.
    public init(displayOrigin: URL) {
        self.displayOrigin = displayOrigin
    }

    /// Whether a URL is a bare HTTP(S) origin safe to open as a display
    /// origin: no credentials, query, fragment, or path beyond `/`.
    public static func isValidDisplayOrigin(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return url.host?.isEmpty == false
            && url.user == nil
            && url.password == nil
            && url.query == nil
            && url.fragment == nil
            && (url.path.isEmpty || url.path == "/")
    }
}

/// Routes a background website notification click to WebKit or its external
/// display-origin fallback.
@MainActor
public protocol NotificationWebsiteClickRouting: AnyObject {
    /// Returns whether WebKit accepted the click dispatch synchronously or the
    /// external display-origin fallback opened successfully.
    func openWebsiteNotification(id: UUID, fallbackDisplayOrigin: URL) -> Bool
}
