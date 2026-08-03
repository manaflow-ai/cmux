public import Foundation

/// The browser-safe repository link projected into sidebar presentation state.
public struct SidebarRepositoryLinkState: Equatable, Sendable {
    /// The Git remote name that supplied the link, such as `origin`.
    public let remoteName: String

    /// The compact repository path presented in the sidebar.
    public let displayName: String

    /// The sanitized HTTP(S) destination opened for the repository.
    public let url: URL

    /// Creates sidebar presentation state for a browser-safe repository link.
    ///
    /// - Parameters:
    ///   - remoteName: The Git remote name that supplied the link.
    ///   - displayName: The compact repository path presented to the user.
    ///   - url: The sanitized HTTP(S) destination opened for the repository.
    public init(remoteName: String, displayName: String, url: URL) {
        self.remoteName = remoteName
        self.displayName = displayName
        self.url = url
    }
}
