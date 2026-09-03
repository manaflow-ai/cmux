public import Foundation

/// A sanitized, browser-safe link to a Git repository remote.
///
/// This value retains the remote name for presentation, derives a compact
/// display name from its repository path, and removes credentials and other
/// non-browser URL components before exposing the destination.
public struct GitRepositoryLink: Equatable, Sendable {
    /// The Git remote name that produced this link, such as `origin`.
    public let remoteName: String

    /// The normalized repository path displayed to the user, without `.git`.
    public let displayName: String

    /// The sanitized HTTP(S) URL that can be opened in a browser.
    public let url: URL

    /// Creates a browser-safe repository link.
    ///
    /// - Parameters:
    ///   - remoteName: The Git remote name that produced the link.
    ///   - displayName: The normalized repository path for presentation.
    ///   - url: The sanitized HTTP(S) browser URL.
    public init(remoteName: String, displayName: String, url: URL) {
        self.remoteName = remoteName
        self.displayName = displayName
        self.url = url
    }
}
