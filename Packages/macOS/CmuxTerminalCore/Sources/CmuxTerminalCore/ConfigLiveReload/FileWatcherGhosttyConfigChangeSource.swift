import CmuxFoundation

/// ``GhosttyConfigChangeSource`` backed by one ``FileWatcher`` per path.
///
/// ``FileWatcher`` also watches the nearest existing ancestor directory and
/// reattaches to the current inode after every event, so a file that is
/// created later, saved atomically (temp file renamed over the original), or
/// moved aside and rewritten (Vim's default backup behavior) keeps reporting
/// changes. Events are not throttled here: the coordinator needs the first
/// event promptly to mark a change pending, and debounces the evaluation
/// itself.
public struct FileWatcherGhosttyConfigChangeSource: GhosttyConfigChangeSource {
    /// Creates the source.
    public init() {}

    public func subscribe(toPaths paths: [String]) async -> GhosttyConfigChangeSubscription {
        let (events, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        // FileWatcher.init opens descriptors synchronously; this nonisolated
        // async requirement runs off the caller's actor.
        let watchers = paths.map { FileWatcher(path: $0) }
        let forwarders = watchers.map { watcher in
            Task {
                for await _ in watcher.events {
                    continuation.yield(())
                }
            }
        }
        return GhosttyConfigChangeSubscription(events: events) {
            for forwarder in forwarders {
                forwarder.cancel()
            }
            for watcher in watchers {
                await watcher.stop()
            }
            continuation.finish()
        }
    }
}
