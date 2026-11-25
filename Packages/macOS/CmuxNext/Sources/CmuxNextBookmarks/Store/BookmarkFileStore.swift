public import Foundation

/// The local bookmark file an older build wrote (bookmarks.md section 2):
/// every profile's tree in one JSON document. Read once to copy it into the
/// home daemon (`bookmarks-v1`, the only writer now), then deleted. An actor,
/// so the read stays off the main thread.
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

    /// Deletes the file once its data lives in the daemon.
    public func remove() throws {
        cache = [:]
        guard exists else { return }
        try FileManager.default.removeItem(at: file)
    }
}
