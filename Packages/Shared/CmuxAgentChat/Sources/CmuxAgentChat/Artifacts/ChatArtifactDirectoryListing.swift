/// A capped listing of one Mac-hosted artifact directory.
public struct ChatArtifactDirectoryListing: Sendable, Equatable, Codable {
    /// Directory entries sorted by name.
    public let entries: [ChatArtifactDirectoryEntry]

    /// Creates a directory listing.
    ///
    /// - Parameter entries: Directory entries sorted by name.
    public init(entries: [ChatArtifactDirectoryEntry]) {
        self.entries = entries
    }
}
