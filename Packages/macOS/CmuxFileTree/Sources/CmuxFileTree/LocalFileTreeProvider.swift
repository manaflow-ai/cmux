/// Browses this Mac's filesystem.
///
/// Listing uses `getattrlistbulk(2)` on a background executor; change
/// observation uses one FSEvents stream per root.
public struct LocalFileTreeProvider: FileTreeProvider {
    private let reader: DirectoryBulkReader
    private let eventLatency: Double

    /// Creates a local provider.
    /// - Parameter eventLatency: FSEvents coalescing window in seconds.
    public init(eventLatency: Double = 0.25) {
        self.reader = DirectoryBulkReader()
        self.eventLatency = eventLatency
    }

    /// Lists one directory without following it into the main actor.
    public func listDirectory(at path: String) async throws -> FileTreeListing {
        try Task.checkCancellation()
        return FileTreeListing(entries: try reader.entries(atPath: path))
    }

    /// Streams FSEvents batches under `rootPath`.
    public func changes(under rootPath: String) -> AsyncStream<FileTreeChangeBatch>? {
        FileSystemEventStream(rootPath: rootPath, latency: eventLatency).makeStream()
    }
}
