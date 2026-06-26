import Foundation

/// Owns one kqueue-backed `DispatchSourceProcess` per distinct agent PID we've
/// ever seen, expiring every pending `WorkstreamItem` for a PID the instant the
/// kernel observes that process exit.
///
/// The kernel fires `.exit` the moment the process dies (or immediately if it's
/// already dead). When that fires the watcher marks every pending item for that
/// PID as `.expired` on the owning ``WorkstreamStore`` and cancels the source.
/// Keyed by PID so the same agent spawning multiple prompts only installs one
/// watcher.
///
/// ## Isolation
/// `pidWatchers` and ``arm(ppid:store:)`` are `@MainActor` (the dictionary is
/// only ever touched from the main actor), while `pidWatcherQueue` is an
/// immutable `let` so the `DispatchSourceProcess` can fire its `.exit` handler
/// off-main; the handler hops back to the main actor before mutating any state.
/// `DispatchSource.make*` is owned here and never exposed, surfaced only as the
/// store mutations it drives (the file-watcher precedent).
public final class WorkstreamPidExitWatcher: @unchecked Sendable {
    /// One kqueue-backed DispatchSource per distinct agent PID we've
    /// ever seen. Keyed by PID so the same agent spawning multiple prompts
    /// only installs one watcher.
    @MainActor private var pidWatchers: [Int: DispatchSourceProcess] = [:]
    private let pidWatcherQueue = DispatchQueue(
        label: "cmux.feed.pidWatcher", qos: .utility
    )

    public init() {}

    /// Installs a one-shot kqueue watcher for `ppid`. The handler
    /// fires the moment the kernel observes process exit (or
    /// immediately if `ppid` is already dead), marks every pending
    /// item for that PID as `.expired` on `store`, and cancels the source.
    /// Idempotent: subsequent calls with the same PID no-op.
    @MainActor
    public func arm(ppid: Int, store: WorkstreamStore) {
        guard ppid > 0, pidWatchers[ppid] == nil else { return }
        let src = DispatchSource.makeProcessSource(
            identifier: pid_t(ppid),
            eventMask: .exit,
            queue: pidWatcherQueue
        )
        src.setEventHandler { [weak self, weak store] in
            Task { @MainActor in
                guard let self else { return }
                store?.expireItems(forPpid: ppid)
                self.pidWatchers[ppid]?.cancel()
                self.pidWatchers.removeValue(forKey: ppid)
            }
        }
        pidWatchers[ppid] = src
        src.resume()
    }
}
