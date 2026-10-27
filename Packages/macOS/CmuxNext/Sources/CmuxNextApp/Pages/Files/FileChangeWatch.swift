import CmuxNextSettings
import CmuxNextWakeups
import Darwin
import Foundation

/// Watches a file page's file (kernel vnode events through ``ConfigFileWatcher``, which follows
/// in-place writes, atomic renames and delete-and-recreate) and reports its new content once per
/// burst: each event restarts a debounce (a visible-class ``MainDeadline`` on the app's deadline
/// scheduler), whose action reads the file on the files lane; the read's reply reports it when its
/// hash differs from ``knownHash`` (nil: deleted). The page's own saves are reported too; the page
/// recognizes them by hash. A kernel event reaches main as one visible-class task on the app's
/// scheduler. Hidden or not, the watch runs: the page's router holds what a hidden page is sent.
final class FileChangeWatch {
    let url: URL
    /// The hash last reported (or read at open); a read with the same hash reports nothing.
    var knownHash: String?
    private let inWorkspace: () -> Bool
    private let mainWork: MainWorkScheduler
    private let work: BackgroundWork
    private let debounce: Duration
    private let onChange: (FileSnapshot?) -> Void
    private var watcher: ConfigFileWatcher?
    /// The burst's debounce: each event pushes it back; its action starts the read.
    private let settle: MainDeadline
    /// Bumped by every event and by ``stop()``: an older read's reply reports nothing.
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

    /// - Parameters:
    ///   - deadlines: The app's deadline scheduler (`AppServices.mainDeadlines`): the debounce is one of its deadlines,
    ///     and its scheduler takes the kernel events and the read's reply.
    ///   - work: The app's lanes (`AppServices.work`): the file is read on its files lane.
    init(url: URL, inWorkspace: @escaping () -> Bool, deadlines: MainDeadlineScheduler, work: BackgroundWork,
         debounce: Duration = .milliseconds(100), onChange: @escaping (FileSnapshot?) -> Void) {
        self.url = url
        self.inWorkspace = inWorkspace
        mainWork = deadlines.work
        self.work = work
        self.debounce = debounce
        self.onChange = onChange
        settle = MainDeadline(owner: "files.change-watch", workClass: .visible, scheduler: deadlines)
    }

    /// Whether a debounce waits to read.
    var isSettling: Bool { settle.isScheduled }

    func start() {
        guard watcher == nil else { return }
        let mainWork = mainWork
        let watcher = ConfigFileWatcher(url: url) { [weak self] in
            mainWork.postFromAnyThread(.visible, owner: "files.change-watch") { self?.noteEvent() }
        }
        self.watcher = watcher
        watcher.start()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        settle.cancel()
        generation += 1
    }

    /// One kernel event for the file (the watcher calls it; tests call it to drive the debounce
    /// without the kernel): restarts the debounce, and drops a read already started.
    func noteEvent() {
        generation += 1
        settle.schedule(after: debounce) { [weak self] in self?.startRead() }
    }

    /// Reads the file on the files lane; the reply reports it unless a later event or a stop came first.
    private func startRead() {
        let generation = generation, url = url, inWorkspace = inWorkspace(), previous = stamp
        work.run(.userVisible, mayBlock: .files) { Self.read(url, inWorkspace: inWorkspace, unless: previous) }
            .reply(on: mainWork, class: .visible, owner: "files.change-watch") { [weak self] read in
                guard let self, self.generation == generation else { return }
                let (stamp, snapshot) = read
                guard stamp != self.stamp else { return }
                self.stamp = stamp
                guard snapshot?.hash != self.knownHash else { return }
                self.knownHash = snapshot?.hash
                self.onChange(snapshot)
            }
    }

    /// The file's stamp, and its content when the stamp differs from `previous` (nil: gone).
    private nonisolated static func read(_ url: URL, inWorkspace: Bool, unless previous: Stamp?) -> (Stamp?, FileSnapshot?) {
        var info = stat()
        // SAFETY: stat reads the NUL-terminated copy of the path made for the call and writes one struct stat
        // into `info`, a local live for the call.
        guard unsafe stat(url.path, &info) == 0 else { return (nil, nil) }
        let stamp = Stamp(device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
                          modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec))
        guard stamp != previous else { return (stamp, nil) }
        return (stamp, FileDocument.current(url, inWorkspace: inWorkspace))
    }
}
