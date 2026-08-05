public import Foundation

/// Canonical identity used to compare local files across aliases and symlinks.
public struct BrowserLocalFileIdentity: Equatable, Hashable, Sendable {
    private let canonicalPath: String

    /// Creates an identity for a local file URL.
    ///
    /// - Parameter url: The local file URL to canonicalize.
    public init?(url: URL) {
        guard url.isFileURL else { return nil }
        canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Creates an identity from a file URL that was already canonicalized by a
    /// deadline-bounded filesystem operation.
    ///
    /// This initializer performs lexical standardization only. Callers must not
    /// pass an unresolved symlink URL.
    public init?(resolvedURL: URL) {
        guard resolvedURL.isFileURL else { return nil }
        canonicalPath = resolvedURL.standardizedFileURL.path
    }
}
