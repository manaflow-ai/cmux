import CmuxNextSettings
import Darwin
import Foundation

/// Watches a file page's file (kernel vnode events through ``ConfigFileWatcher``, which follows
/// in-place writes, atomic renames and delete-and-recreate) and reports its new content once per
/// burst: each event restarts a debounce on the injected clock, then the file is read off the main
/// actor and reported when its hash differs from ``knownHash`` (nil: deleted). The page's own
/// saves are reported too; the page recognizes them by hash.
final class FileChangeWatch {
    let url: URL
    /// The hash last reported (or read at open); a read with the same hash reports nothing.
    var knownHash: String?
    private let inWorkspace: () -> Bool
    private let clock: any Clock<Duration>
    private let debounce: Duration
    private let onChange: (FileSnapshot?) -> Void
    private var watcher: ConfigFileWatcher?
    private var pending: Task<Void, Never>?
    private var generation = 0
    /// The file's identity, size and modification time at the last read: an event that changes
    /// none of them (an access-time update from the read itself) reads nothing.
    private var stamp: Stamp?

    nonisolated struct Stamp: Equatable, Sendable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modified: Int64
    }

    init(url: URL, inWorkspace: @escaping () -> Bool, clock: any Clock<Duration>, debounce: Duration = .milliseconds(100),
         onChange: @escaping (FileSnapshot?) -> Void) {
        self.url = url
        self.inWorkspace = inWorkspace
        self.clock = clock
        self.debounce = debounce
        self.onChange = onChange
    }

    /// Debounces in flight.
    var pendingCount: Int { pending == nil ? 0 : 1 }

    /// Returns once no debounce or read is in flight (tests await it instead of wall time).
    func settled() async {
        while let task = pending {
            await task.value
            if pending == task { pending = nil }
        }
    }

    func start() {
        guard watcher == nil else { return }
        let watcher = ConfigFileWatcher(url: url) { [weak self] in
            // task-owner: hops one kernel event to the main actor; the debounce owns the work
            Task { @MainActor in self?.noteEvent() }
        }
        self.watcher = watcher
        watcher.start()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        pending?.cancel()
        pending = nil
    }

    /// One kernel event for the file (the watcher calls it; tests call it to drive the debounce
    /// without the kernel): restarts the debounce.
    func noteEvent() {
        pending?.cancel()
        generation += 1
        let generation = generation
        let clock = clock, debounce = debounce, url = url, inWorkspace = inWorkspace()
        pending = Task { [weak self] in
            do {
                try await clock.sleep(for: debounce) // wakeup-allow: one debounce per disk event burst, cancelled by the next event
            } catch {
                return
            }
            let (stamp, snapshot) = await Self.read(url, inWorkspace: inWorkspace, unless: self?.stamp)
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.pending = nil
            guard stamp != self.stamp else { return }
            self.stamp = stamp
            guard snapshot?.hash != self.knownHash else { return }
            self.knownHash = snapshot?.hash
            self.onChange(snapshot)
        }
    }

    /// The file's stamp, and its content when the stamp differs from `previous` (nil: gone).
    @concurrent private static func read(_ url: URL, inWorkspace: Bool, unless previous: Stamp?) async -> (Stamp?, FileSnapshot?) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return (nil, nil) }
        let stamp = Stamp(device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
                          modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec))
        guard stamp != previous else { return (stamp, nil) }
        return (stamp, FileDocument.current(url, inWorkspace: inWorkspace))
    }
}
