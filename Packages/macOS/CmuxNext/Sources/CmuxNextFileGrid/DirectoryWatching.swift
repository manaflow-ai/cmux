/// Reports changes under folders. ``DirectoryWatcher`` is the FSEvents one;
/// tests pass one that reports only what they say.
public nonisolated protocol DirectoryWatching: Sendable {
    /// The changes under `paths`, one batch per report.
    ///
    /// - Parameter paths: folders to watch.
    func events(for paths: [String]) -> AsyncStream<[DirectoryWatcherEvent]>
}
