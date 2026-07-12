import Foundation

/// Native metadata for one file rendered by the shared web diff viewer.
public struct MobileDiffFile: Decodable, Equatable, Identifiable, Sendable {
    /// The stable identifier supplied by the renderer.
    public let id: String
    /// The repository-relative file path.
    public let path: String
    /// The number of added lines.
    public let added: Int
    /// The number of deleted lines.
    public let deleted: Int

    /// Creates native metadata for a rendered diff file.
    public init(id: String, path: String, added: Int, deleted: Int) {
        self.id = id
        self.path = path
        self.added = added
        self.deleted = deleted
    }

    /// The final path component displayed by native navigation controls.
    public var name: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}
