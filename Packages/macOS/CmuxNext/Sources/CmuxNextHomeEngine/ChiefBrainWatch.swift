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
    private var source: (any DispatchSourceProcess)?
    /// The process the armed source watches; an event for another pid is stale.
    private var watchedPID: pid_t?
    private var deaths: [ContinuousClock.Instant] = []
    private var stopped = false
    private var restarting = false
    private let clock = ContinuousClock()
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")

    static let deathLimit = 3
    static let deathWindow: Duration = .seconds(60)

    public init(home: ChiefHome, restart: @escaping Restart, watching: Watching? = nil) {
        self.home = home
        self.restart = restart
        self.watching = watching
    }

    /// Watches `pid`, or the host that holds the lock now when `pid` is nil.
    public func watch(_ pid: pid_t?) {
        guard !stopped else { return }
        source?.cancel()
        source = nil
        guard let pid = pid ?? ChiefHostStop.runningHostPID(home: home) else {
            logger.info("chief brain watch: no host process to watch")
            setWatched(nil)
            return
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
        setWatched(nil)
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
        if let other = ChiefHostStop.runningHostPID(home: home), other != pid {
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
            if stopped || shutdown, let next, ChiefHostStop.isChiefHost(next) {
                kill(next, SIGTERM)
                return
            }
            watch(next)
        }
    }
}
