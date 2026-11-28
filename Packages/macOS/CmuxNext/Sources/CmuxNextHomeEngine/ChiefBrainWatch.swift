import CmuxNextHomeModel
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
///
/// The decisions (what to arm, cancel, read, report, restart or terminate) are
/// `chief_brain.watch_step` in cmux-home-rules; this class keeps the kernel sources, the lock
/// reads, the `kill` calls and the restart, and runs the step's effects in order.
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
    /// Whether a pid runs the "cmux Files (dev)" launcher (``ChiefHostStop/isFilesHostLauncher(_:)``).
    private let isFilesHostLauncher: (pid_t) -> Bool
    private var source: (any DispatchSourceProcess)?
    /// The kernel sources that look for a host's lock while none is watched (see ``armOnLock``).
    private var lockFileSource: (any DispatchSourceFileSystemObject)?
    private var lockFolderSource: (any DispatchSourceFileSystemObject)?
    /// How many descriptors the lock watch has opened. An arm that replaces a source it already
    /// holds raises it, which is the window ``armOnLock`` must not open; the tests read it.
    private(set) var lockSourceOpens = 0
    /// The rules' state between steps.
    private var state = WatchState()
    /// It stopped restarting a host that kept dying (``deathLimit`` within a minute), until
    /// the next ask or a host it finds; Home's Auto then gives the Hosted Chief (``ChiefHome/isOn(canStart:gaveUp:isChiefHost:)``).
    public var hasGivenUp: Bool { state.hasGivenUp == true }
    private let clock = ContinuousClock()
    /// The origin of the death times the rules keep, in milliseconds since it.
    private let origin: ContinuousClock.Instant
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")

    /// The rules' `DEATH_LIMIT` (`chief_brain::watch`); the tests read it.
    static let deathLimit = 3

    public init(home: ChiefHome, restart: @escaping Restart, watching: Watching? = nil,
                isChiefHost: @escaping (pid_t) -> Bool = ChiefHostStop.isChiefHost,
                isFilesHostLauncher: @escaping (pid_t) -> Bool = ChiefHostStop.isFilesHostLauncher) {
        self.home = home
        self.restart = restart
        self.watching = watching
        self.isChiefHost = isChiefHost
        self.isFilesHostLauncher = isFilesHostLauncher
        origin = clock.now
    }

    private var lockedPID: pid_t? {
        ChiefHostStop.runningHostPID(home: home, isChiefHost: isChiefHost)
    }

    /// Watches `pid`, or the host that holds the lock now when `pid` is nil.
    public func watch(_ pid: pid_t?) {
        guard state.stopped != true else { return }
        step(WatchEvent(kind: "watch", pid: pid, locked: lockedPID, launcher: pid.map(isFilesHostLauncher) ?? false))
    }

    /// Quit stopped it for good.
    public var isStopped: Bool { state.stopped == true }

    /// Whether a host process is watched now.
    public var isWatching: Bool { source != nil || state.restarting == true }

    /// Quit: the brain stops on purpose and is not started again.
    public func stop() {
        step(WatchEvent(kind: "stop"))
    }

    /// A launch whose pid the shell did not print leaves nothing to watch until the host takes the
    /// home's lock, which it does a moment later. So while no host is watched, the kernel says when
    /// the lock changes and the watch looks again: no polling and no timer.
    ///
    /// Two sources, because the host writes its pid into the lock file in place: a modified lock
    /// raises an event on the **file**, never on the folder that holds it. The folder's event is for
    /// the lock's first creation on a fresh home. Arming only ever **adds** the source it lacks,
    /// and a host that is already watched arms nothing.
    ///
    /// The tests call this directly. The rules reach it only through a folder change with no
    /// pending host, so it is the rules' `arm_on_lock` run here: arm, then the `mayHaveHost` read.
    func armOnLock() {
        guard state.stopped != true, state.sourcePid == nil else { return }
        ensureLockSources()
        guard state.restarting != true, state.sourcePid == nil, let pid = lockedPID else { return }
        watch(pid)
    }

    /// One step of `chief_brain.watch_step`; the state is kept before the effects run, since an
    /// effect may step again. A failed call changes nothing.
    private func step(_ event: WatchEvent) {
        guard let reply: WatchReply = try? HomeRules.chiefBrain("watch_step", WatchRequest(state: state, event: event))
        else { return }
        state = reply.state
        for effect in reply.effects { run(effect) }
    }

    private func run(_ effect: WatchEffect) {
        switch effect.kind {
        case "cancelExitSource":
            source?.cancel()
            source = nil
        case "armExitSource":
            if let pid = effect.pid { armExitSource(pid) }
        case "ensureLockSources":
            ensureLockSources()
        case "cancelLockSources":
            cancelLockSources()
        case "readLock":
            step(WatchEvent(kind: "lockRead", locked: lockedPID))
        case "report":
            watching?(effect.pid)
        case "restart":
            restartHost()
        case "terminate":
            if let pid = effect.pid { kill(pid, SIGTERM) }
        case "log":
            let message = effect.message ?? ""
            if effect.level == "error" {
                logger.error("\(message, privacy: .public)")
            } else {
                logger.info("\(message, privacy: .public)")
            }
        default:
            logger.error("chief brain watch: unknown effect \(effect.kind, privacy: .public)")
        }
    }

    private func armExitSource(_ pid: pid_t) {
        source?.cancel()
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

    /// The lock, or the folder holding it, changed. The lock read it may need runs on the main
    /// actor: one line of a small local file plus a `proc_pidpath`, once per lock change.
    private func lockChanged(folder: Bool) {
        guard state.stopped != true else { return }
        step(WatchEvent(kind: "lockChanged", folder: folder))
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
        lockFileSource?.cancel()
        lockFileSource = nil
        lockFolderSource?.cancel()
        lockFolderSource = nil
    }

    private var shutdownMarkerExists: Bool {
        // concurrency-allow: one small stat at a brain exit or after a restart
        FileManager.default.fileExists(atPath: home.shutdownMarker.path)
    }

    private func exited(_ pid: pid_t) {
        // The rules drop a late event of an older watch, or a second report of the same exit.
        guard state.stopped != true, state.restarting != true, pid == state.watchedPid else { return }
        let nowMs = Double((clock.now - origin) / .milliseconds(1))
        step(WatchEvent(kind: "exited", pid: pid, locked: lockedPID, shutdownMarker: shutdownMarkerExists, nowMs: nowMs))
    }

    private func restartHost() {
        // task-owner: one restart; ends when the host is started
        Task { [weak self] in
            guard let self else { return }
            let next = await restart()
            let shutdown = shutdownMarkerExists
            // Quit, or `cmux chief shutdown`, came while it started: this host must not outlive it.
            let nextIsHost = (state.stopped == true || shutdown)
                && next.map { isChiefHost($0) || ChiefHostStop.isFilesHostLauncher($0) } == true
            step(WatchEvent(kind: "restarted", locked: lockedPID, launcher: next.map(isFilesHostLauncher) ?? false,
                            shutdownMarker: shutdown, next: next, nextIsHost: nextIsHost))
        }
    }
}

/// `chief_brain::watch::WatchState`; every field is defaulted on the Rust side.
private nonisolated struct WatchState: Codable {
    nonisolated struct ReadFor: Codable {
        var kind: String
        var pid: Int32?
        var launcher: Bool?
    }

    var stopped: Bool?
    var restarting: Bool?
    var hasGivenUp: Bool?
    var sourcePid: Int32?
    var watchedPid: Int32?
    var pendingLockPid: Int32?
    var pendingLauncher: Bool?
    var deathsMs: [Double]?
    var readFor: ReadFor?
}

/// `chief_brain::watch::WatchEvent`, flat: `kind` names the case.
private nonisolated struct WatchEvent: Encodable {
    var kind: String
    var pid: Int32?
    var locked: Int32?
    var launcher: Bool?
    var folder: Bool?
    var shutdownMarker: Bool?
    var nowMs: Double?
    var next: Int32?
    var nextIsHost: Bool?
}

/// `chief_brain::watch::WatchEffect`, flat.
private nonisolated struct WatchEffect: Decodable {
    var kind: String
    var pid: Int32?
    var level: String?
    var message: String?
}

private nonisolated struct WatchRequest: Encodable {
    var state: WatchState
    var event: WatchEvent
}

private nonisolated struct WatchReply: Decodable {
    var state: WatchState
    var effects: [WatchEffect]
}
