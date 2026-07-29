public import Foundation

/// Canonical identity used to compare local files across aliases and symlinks.
public struct BrowserLocalFileIdentity: Equatable, Hashable, Sendable {
    private let canonicalPath: String

    /// Creates an identity for a local file URL.
    public init?(url: URL) {
        guard url.isFileURL else { return nil }
        canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
