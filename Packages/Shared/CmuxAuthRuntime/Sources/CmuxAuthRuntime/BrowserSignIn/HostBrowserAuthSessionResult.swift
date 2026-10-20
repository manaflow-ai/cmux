public import Foundation

/// The terminal result of one hosted-browser auth attempt.
public enum HostBrowserAuthSessionResult: Equatable, Sendable {
    /// The hosted page redirected to the app's auth callback URL.
    case callback(URL)
    /// The user or app deliberately cancelled the browser session.
    case cancelled(reason: String)
    /// The browser session failed before returning a usable callback.
    case failed(reason: String)
}
