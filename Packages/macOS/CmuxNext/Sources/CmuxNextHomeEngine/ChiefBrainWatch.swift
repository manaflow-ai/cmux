import Darwin
public import Foundation
import os

/// Starts this build's brain host again when it dies (one Chief per build,
/// `ChiefHome`). It waits on the kernel's exit event of the host process
/// (no polling). When the host exits and another `optchat-chief` holds the
/// home's lock (one the `cmux chief` CLI started), it watches that one
/// instead. A host that `cmux chief shutdown` stopped (its marker,
/// `ChiefHome.shutdownMarker`) is not started again until asked. A host that dies three times within a minute is not started
/// again until Home or Settings asks, so a host that cannot start never loops.
@MainActor
public final class ChiefBrainWatch {
    /// Starts the host; the pid to watch next, nil when it did not start.
    public typealias Restart = @MainActor () async -> pid_t?
    /// The host process watched now (nil: none), each time it changes.
    public typealias Watching = @MainActor (pid_t?) -> Void

    private let home: ChiefHome
    private let restart: Restart
    private let watching: Watching?
    /// Whether a pid runs an `optchat-chief`; the tests name a stand-in process instead.
    private let isChiefHost: (pid_t) -> Bool
    private var source: (any DispatchSourceProcess)?
    /// The kernel sources that look for a host's lock while none is watched (see ``armOnLock``).
    private var lockFileSource: (any DispatchSourceFileSystemObject)?
    private var lockFolderSource: (any DispatchSourceFileSystemObject)?
    /// How many descriptors the lock watch has opened. An arm that replaces a source it already
    /// holds raises it, which is the window ``armOnLock`` must not open; the tests read it.
    private(set) var lockSourceOpens = 0
    /// The watched host whose lock does not name it yet (see ``watch(_:)``); nil when the lock is
    /// readable, which is every case but a launch that printed its pid.
    private var pendingLockPID: pid_t?
    /// The process the armed source watches; an event for another pid is stale.
    private var watchedPID: pid_t?
    private var deaths: [ContinuousClock.Instant] = []
    private var stopped = false
    private var restarting = false
    private let clock = ContinuousClock()
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")

    static let deathLimit = 3
    static let deathWindow: Duration = .seconds(60)

    public init(home: ChiefHome, restart: @escaping Restart, watching: Watching? = nil,
                isChiefHost: @escaping (pid_t) -> Bool = ChiefHostStop.isChiefHost) {
        self.home = home
        self.restart = restart
        self.watching = watching
        self.isChiefHost = isChiefHost
    }

    /// Watches `pid`, or the host that holds the lock now when `pid` is nil.
    public func watch(_ pid: pid_t?) {
        guard !stopped else { return }
        source?.cancel()
        source = nil
        let locked = ChiefHostStop.runningHostPID(home: home, isChiefHost: isChiefHost)
        guard let pid = pid ?? locked else {
            logger.info("chief brain watch: no host process to watch")
            pendingLockPID = nil
            setWatched(nil)
            armOnLock()
            return
        }
        // A launch that printed its pid is watched before the host writes that pid into the lock,
        // and a reader of the brain's liveness reads the lock, not this process source. So the lock
        // watch stays armed until the lock names this host, and the write that names it tells the
        // reader again (``lockChanged(folder:)``).
        if locked == pid {
            pendingLockPID = nil
            cancelLockSources()
        } else {
            // Arm before reading again, and read again: the host writes its pid a moment after the
            // launch printed it, and a write that lands between a read and the arming would raise
            // its event on a source that does not exist yet, with nothing left to read the lock.
            ensureLockSources()
            if ChiefHostStop.runningHostPID(home: home, isChiefHost: isChiefHost) == pid {
                pendingLockPID = nil
                cancelLockSources()
            } else {
                pendingLockPID = pid
            }
        }
        setWatched(pid)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        weak let weakSelf = self
        source.setEventHandler {
            // task-owner: one hop to the main actor per exit event
            Task { @MainActor in weakSelf?.exited(pid) }
        }
        self.source = source
        source.resume()
        // An exit before the source was armed raises no event.
        if kill(pid, 0) != 0, errno == ESRCH { exited(pid) }
    }

    /// Quit stopped it for good.
    public var isStopped: Bool { stopped }

    /// Whether a host process is watched now.
    public var isWatching: Bool { source != nil || restarting }

    /// Quit: the brain stops on purpose and is not started again.
    public func stop() {
        stopped = true
        source?.cancel()
        source = nil
        cancelLockSources()
        setWatched(nil)
    }

    /// A launch whose pid the shell did not print leaves nothing to watch until the host takes the
    /// home's lock, which it does a moment later. So while no host is watched, the kernel says when
    /// the lock changes and the watch looks again: no polling and no timer.
    ///
    /// Two sources, because the host writes its pid into the lock file in place (optchat-chief's
    /// `lock.rs` truncates it and writes, and never removes the file): a modified lock raises an
    /// event on the **file**, never on the folder that holds it. The folder's event is for the
    /// lock's first creation on a fresh home, where there is no file to watch yet; it arms again,
    /// which then adds the file. They end when a host is watched and at ``stop()``, and a reader
    /// of the brain's liveness (Home's default Chief) hears the host through ``Watching``.
    ///
    /// Arming only ever **adds** the source it lacks, and a host that is already watched arms
    /// nothing: cancelling the folder source to reopen it would leave a window where a lock
    /// created in it raises no event, and a folder event that the main actor runs after
    /// ``watch(_:)`` found a host must not open these descriptors again for that host's lifetime.
    func armOnLock() {
        guard !stopped, source == nil else { return }
        ensureLockSources()
        // The host may have taken the lock between the read that found none and this arming.
        lockMayHaveAHost()
    }

    /// Opens the lock file's source and the state folder's, each only when it is missing.
    private func ensureLockSources() {
        let state = home.root.appendingPathComponent("state")
        if lockFolderSource == nil {
            lockFolderSource = lockSource(at: state) { $0.lockChanged(folder: true) }
        }
        if lockFileSource == nil {
            lockFileSource = lockSource(at: state.appendingPathComponent("host.lock")) { $0.lockChanged(folder: false) }
        }
        if lockFolderSource == nil, lockFileSource == nil {
            logger.info("chief brain watch: no lock and no state folder to watch")
        }
    }

    /// The lock, or the folder holding it, changed.
    ///
    /// The lock read runs here on the main actor, as it does in ``watch(_:)`` and ``exited(_:)``:
    /// it is one line of a small local file plus a `proc_pidpath`, once per lock change, and these
    /// sources exist only while no host is watched, so there is no stream of events to read on. Off
    /// the main actor it would need a generation check, and `isChiefHost` to cross isolation; Home's
    /// own repeated reads are the ones that go off it (``HomeService/localChiefRuns(_:)``).
    private func lockChanged(folder: Bool) {
        guard !stopped else { return }
        guard let pending = pendingLockPID else {
            // A folder change may be the lock's creation: arm again, which adds the file.
            if folder { armOnLock() } else { lockMayHaveAHost() }
            return
        }
        // A host is watched, but its lock did not name it yet. Once it does, a reader that reads
        // the lock (Home's default Chief) hears it; the pid has not changed, so ``setWatched`` would
        // drop it and `watching` is told directly.
        //
        // The arming comes first: a lock created empty is read as naming nobody, and the pid the
        // host writes a moment later would raise its event on a file source that did not exist yet.
        if folder { ensureLockSources() }
        guard ChiefHostStop.runningHostPID(home: home, isChiefHost: isChiefHost) == pending else { return }
        pendingLockPID = nil
        cancelLockSources()
        watching?(pending)
    }

    /// One `.write` source on `url`, or nil when it cannot be opened (no such file yet).
    private func lockSource(at url: URL,
                            _ changed: @escaping @MainActor (ChiefBrainWatch) -> Void) -> (any DispatchSourceFileSystemObject)? {
        // `O_CLOEXEC`, so the descriptor never reaches a child: the brain host and its acpmux
        // daemon outlive the app's watch, and an inherited descriptor would keep the home's
        // state folder busy after it (optchat-chief's `lock.rs` takes its own lock the same way).
        // concurrency-allow: one open of a local path while no host is watched
        let fd = open(url.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        lockSourceOpens += 1
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        weak let weakSelf = self
        source.setEventHandler {
            // task-owner: one hop to the main actor per lock change
            Task { @MainActor in
                guard let self = weakSelf else { return }
                changed(self)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func cancelLockSources() {
        pendingLockPID = nil
        lockFileSource?.cancel()
        lockFileSource = nil
        lockFolderSource?.cancel()
        lockFolderSource = nil
    }

    /// The home's lock changed while nothing was watched: watch the host that holds it now, if one
    /// does. ``watch(_:)`` cancels these sources once it has a host.
    private func lockMayHaveAHost() {
        guard !stopped, !restarting, source == nil,
              let pid = ChiefHostStop.runningHostPID(home: home, isChiefHost: isChiefHost) else { return }
        watch(pid)
    }

    /// The watched host changed: `watching` hears it once per change, so a
    /// reader of the brain's liveness (Home's default Chief) follows a host
    /// that started or died without asking for it.
    private func setWatched(_ pid: pid_t?) {
        guard watchedPID != pid else { return }
        watchedPID = pid
        watching?(pid)
    }

    private func exited(_ pid: pid_t) {
        // One event per watched process: a late event of an older watch, or a
        // second report of the same exit, does nothing.
        guard !stopped, !restarting, pid == watchedPID else { return }
        setWatched(nil)
        source?.cancel()
        source = nil
        if let other = ChiefHostStop.runningHostPID(home: home, isChiefHost: isChiefHost), other != pid {
            logger.info("chief brain \(pid, privacy: .public) exited; host \(other, privacy: .public) holds the lock")
            watch(other)
            return
        }
        // concurrency-allow: one small stat at a brain exit
        if FileManager.default.fileExists(atPath: home.shutdownMarker.path) {
            logger.info("chief brain \(pid, privacy: .public) stopped by cmux chief shutdown; not restarting until asked")
            return
        }
        let now = clock.now
        deaths = deaths.filter { now - $0 < Self.deathWindow } + [now]
        guard deaths.count < Self.deathLimit else {
            logger.error("chief brain exited \(self.deaths.count, privacy: .public) times within a minute; not restarting until asked again")
            return
        }
        logger.info("chief brain \(pid, privacy: .public) exited; starting it again")
        restarting = true
        // task-owner: one restart; ends when the host is started
        Task { [weak self] in
            guard let self else { return }
            let next = await restart()
            restarting = false
            // Quit, or `cmux chief shutdown`, came while it started: this
            // host must not outlive it.
            // concurrency-allow: one small stat after a restart
            let shutdown = FileManager.default.fileExists(atPath: home.shutdownMarker.path)
            if stopped || shutdown, let next, isChiefHost(next) {
                kill(next, SIGTERM)
                return
            }
            watch(next)
        }
    }
}
