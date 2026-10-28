public import Foundation

/// The classic session file a migration read, and what tells a later save of it apart.
public nonisolated struct ClassicMigrationSource: Codable, Equatable, Sendable {
    /// The file read (the session file, its `-previous` copy, or a `session-history` entry).
    public let path: String
    /// The classic bundle id whose session it is (`com.cmuxterm.app`, `com.cmuxterm.app.nightly`, ...).
    public let bundleID: String
    public let size: Int
    /// Its modification time, seconds since 1970.
    public let modifiedAt: Double
    /// The snapshot's own `createdAt`; nil when the file has none.
    public let createdAt: Double?

    public init(path: String, bundleID: String, size: Int, modifiedAt: Double, createdAt: Double?) {
        self.path = path
        self.bundleID = bundleID
        self.size = size
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
    }

    /// Whether `other` is the same save of the same channel's session.
    ///
    /// The path is left out: the primary file and the `-previous` copy of one
    /// save are the same state.
    public func isSameSave(as other: ClassicMigrationSource) -> Bool {
        bundleID == other.bundleID && (createdAt != nil ? createdAt == other.createdAt : size == other.size && modifiedAt == other.modifiedAt)
    }
}
