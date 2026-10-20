public import Foundation

/// A single source profile discovered inside an installed browser's data
/// directory, used as an import source.
public struct InstalledBrowserProfile: Identifiable, Hashable, Sendable {
    /// Human-readable profile name (from the browser's metadata or directory).
    public let displayName: String
    /// Filesystem location of the profile's data directory.
    public let rootURL: URL
    /// Whether this is the browser's default/primary profile.
    public let isDefault: Bool

    /// Stable identifier derived from the canonicalized profile path.
    public var id: String {
        rootURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Creates an installed-browser profile descriptor.
    ///
    /// - Parameters:
    ///   - displayName: Human-readable profile name.
    ///   - rootURL: Filesystem location of the profile's data directory.
    ///   - isDefault: Whether this is the browser's default profile.
    public init(displayName: String, rootURL: URL, isDefault: Bool) {
        self.displayName = displayName
        self.rootURL = rootURL
        self.isDefault = isDefault
    }
}
