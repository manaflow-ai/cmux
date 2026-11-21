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
    /// The Firefox container (`userContextId`) this source reads, or `nil` for
    /// the profile's cookies outside any container.
    public let containerID: Int?

    /// Stable identifier derived from the canonicalized profile path and, for a
    /// container, its `userContextId`.
    public var id: String {
        let path = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard let containerID else { return path }
        return "\(path)#userContextId=\(containerID)"
    }

    /// Creates an installed-browser profile descriptor.
    ///
    /// - Parameters:
    ///   - displayName: Human-readable profile name.
    ///   - rootURL: Filesystem location of the profile's data directory.
    ///   - isDefault: Whether this is the browser's default profile.
    ///   - containerID: The Firefox container this source reads, if any.
    public init(displayName: String, rootURL: URL, isDefault: Bool, containerID: Int? = nil) {
        self.displayName = displayName
        self.rootURL = rootURL
        self.isDefault = isDefault
        self.containerID = containerID
    }
}
