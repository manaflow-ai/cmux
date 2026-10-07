public import Foundation

/// The local bookmark file (bookmarks.md section 2): every profile's tree in
/// one JSON document, used while the home daemon lacks `bookmarks-v1`. An
/// actor, so reads and writes stay off the main thread; each save writes
/// the whole file atomically.
public actor BookmarkFileStore {
    public let file: URL
    private var cache: [String: [BookmarkNode]]?

    private nonisolated struct Document: Codable {
        var version: Int
        var profiles: [String: [BookmarkNode]]
    }

    public init(file: URL) {
        self.file = file
    }

    /// Every profile's nodes in tree order (empty when there is no file).
    public func load() -> [String: [BookmarkNode]] {
        if let cache { return cache }
        let loaded: [String: [BookmarkNode]]
        if let data = try? Data(contentsOf: file), let document = try? JSONDecoder().decode(Document.self, from: data) {
            loaded = document.profiles
        } else {
            loaded = [:]
        }
        cache = loaded
        return loaded
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    /// Replaces one profile's nodes (an empty list removes the profile).
    public func save(profile: String, nodes: [BookmarkNode]) throws {
        var profiles = load()
        profiles[profile] = nodes.isEmpty ? nil : nodes
        cache = profiles
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(version: 1, profiles: profiles))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    /// Deletes the file once its data lives in the daemon.
    public func remove() throws {
        cache = [:]
        guard exists else { return }
        try FileManager.default.removeItem(at: file)
    }
}
