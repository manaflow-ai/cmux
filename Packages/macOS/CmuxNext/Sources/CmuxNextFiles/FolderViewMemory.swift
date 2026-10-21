public import Foundation

/// Each folder's view and sort order, as Finder keeps them per folder
/// (Finder writes `.DS_Store`; Files keeps a capped list in defaults).
///
/// Only folders whose view someone changed are stored, newest first, so the
/// list stays small; the oldest fall off past `capacity`.
public struct FolderViewMemory {
    /// What one folder remembers.
    public struct Prefs: Codable, Equatable, Sendable {
        /// Icons, list or columns.
        public var viewMode: FileViewMode
        /// The order.
        public var sortOrder: FileSortOrder

        /// Makes a record.
        public init(viewMode: FileViewMode, sortOrder: FileSortOrder) {
            self.viewMode = viewMode
            self.sortOrder = sortOrder
        }
    }

    private struct Stored: Codable {
        var path: String
        var prefs: Prefs
    }

    private let defaults: UserDefaults
    private let capacity: Int
    private static let key = "files.folderViews"

    /// Makes a memory in `defaults` keeping at most `capacity` folders.
    public init(defaults: UserDefaults, capacity: Int = 500) {
        self.defaults = defaults
        self.capacity = capacity
    }

    /// What `folder` remembers, if anything.
    public func prefs(for folder: URL) -> Prefs? {
        let path = folder.standardizedFileURL.path
        return load().first { $0.path == path }?.prefs
    }

    /// Remembers `prefs` for `folder` (moving it to the front).
    public func remember(_ prefs: Prefs, for folder: URL) {
        let path = folder.standardizedFileURL.path
        var list = load().filter { $0.path != path }
        list.insert(Stored(path: path, prefs: prefs), at: 0)
        if list.count > capacity { list.removeLast(list.count - capacity) }
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: Self.key) }
    }

    private func load() -> [Stored] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([Stored].self, from: data)) ?? []
    }
}
