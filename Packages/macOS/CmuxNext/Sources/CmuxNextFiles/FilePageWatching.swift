/// Watches a file page's file and reports its new content (nil: deleted) through the callback
/// it was made with. ``FileChangeWatch`` on this Mac, ``RemoteFileChangeWatch`` on a Cloud machine.
@MainActor public protocol FilePageWatching: AnyObject {
    /// The hash last reported (or read at open); a read with the same hash reports nothing.
    var knownHash: String? { get set }
    /// Begins watching until stopped.
    func start()
    /// Cancels pending work and releases the watcher.
    func stop()
}
