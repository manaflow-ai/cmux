/// One change FSEvents reported under a watched folder.
public nonisolated struct DirectoryWatcherEvent: Sendable, Hashable {
    /// The changed item's path (a file, or a folder).
    public var path: String
    /// The changed item is a folder.
    public var isDirectory: Bool
    /// FSEvents lost detail (dropped events, a changed root, coalesced
    /// subfolders): the folder must be listed again.
    public var mustRescan: Bool

    /// Makes an event.
    ///
    /// - Parameters:
    ///   - path: the changed item's path.
    ///   - isDirectory: the item is a folder.
    ///   - mustRescan: the watched folder must be listed again.
    public init(path: String, isDirectory: Bool = false, mustRescan: Bool = false) {
        self.path = path
        self.isDirectory = isDirectory
        self.mustRescan = mustRescan
    }
}
