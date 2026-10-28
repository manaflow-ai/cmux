public import CmuxNextWakeups
import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
import Darwin
import Dispatch
import Foundation

/// An event that can make a retry succeed. Fired by callers (network path
/// change, app activation) and by a kernel vnode watch on a socket file's
/// directory (``watch(file:companions:)``): the watch fires only when the
/// file's identity differs from the one recorded after the last failed attempt
/// (``rebaseline()``), so the loop's own attempts (a `server ensure` that
/// recreates the socket) never wake it again.
///
/// The socket's folder may not exist yet (a first launch with no daemon home):
/// the watch is then on the deepest folder on the path that exists and opens,
/// and it moves down as the missing folders appear. An entry change there that
/// is not the next folder down or the file itself does not wake the loop (one
/// `folder` record in the ``WakeupLedger``).
public final class RetryWake: Sendable {
    public enum Cause: Sendable, Equatable {
        /// ``fire()``: an explicit event (app activation, network, a reconnect action).
        case event
        /// The watched socket changed (``watch(file:companions:)``).
        case socket
        case timer
        case cancelled
    }

    /// What ``rebaseline()`` found at the watched file.
    public enum WatchedFile: Sendable, Equatable {
        /// The file exists, with this identity (a replaced file has another one).
        case present(Identity)
        /// The file is missing and the folders toward it are watched: its creation wakes the wait.
        case missing
        /// No file is watched, or no event can tell its creation: no folder on its path opens
        /// (no descriptor left), or a folder on the way to it exists but does not open (no read
        /// permission, a privacy-protected folder), so changes inside it reach no watch. Only the
        /// timer and explicit events wake the wait.
        case unwatched
    }

    /// A file's identity (device and inode): a file replaced at the same path has another one.
    public struct Identity: Sendable, Equatable {
        var device: dev_t
        var inode: ino_t
    }

    public let owner: String
    private let ledger: WakeupLedger
    private let probe: RetryWakeProbe
    private let queue = DispatchQueue(label: "com.cmuxterm.next.retry-wake", qos: .userInitiated)
    private let state = Mutex<State>(State())
    /// The vnode watch's record in the launch's arm census (Debug and bench builds, p08-startup-085).
    private let census: ArmCensusWatch

    /// The folder the vnode watch is on.
    private struct WatchedFolder {
        var path: String
        var identity: Identity
        /// The folder one level down toward the file that exists but did not open (not
        /// readable): it is no reason to move the watch down.
        var blocked: Identity?
    }

    private struct State {
        /// An event that came with no waiter (`.event` wins over `.socket`).
        var latched: Cause?
        var waiter: OnceContinuation<Cause, OnceContinuationError>?
        /// The waiter wakes on a socket change too.
        var waiterTakesSocket = true
        var timer: DemandTimer?
        var file: String?
        /// Files beside `file` that wake too (a daemon's ready marker).
        var companions: [String] = []
        var baseline: [Identity?] = []
        var folder: WatchedFolder?
        var source: (any DispatchSourceFileSystemObject)?
    }

    /// - Parameters:
    ///   - owner: The name its wakeups are recorded under.
    ///   - ledger: Where its wakeups are recorded.
    ///   - file: The line that made it, named by the arm census (leave the default).
    ///   - line: See `file`.
    public convenience init(owner: String, ledger: WakeupLedger = .shared, file: StaticString = #fileID, line: UInt = #line) {
        self.init(owner: owner, ledger: ledger, probe: RetryWakeProbe(), file: file, line: line)
    }

    /// `probe`: tests act at the points a race needs (``RetryWakeProbe``).
    init(owner: String, ledger: WakeupLedger = .shared, probe: RetryWakeProbe, file: StaticString = #fileID, line: UInt = #line) {
        self.owner = owner
        self.ledger = ledger
        self.probe = probe
        census = ArmCensusWatch(ledger: ledger, .watcher, owner: owner, file: file, line: line)
    }

    deinit {
        state.withLock { $0.source?.cancel() }
    }

    /// Something changed that may let a retry succeed.
    public func fire() {
        resume(.event, latchIfIdle: true)
    }

    /// Watches `path`; a change of `path` itself (created, removed, replaced)
    /// fires, and so does a change of any of `companions` (files in the same
    /// directory, such as the daemon's ready marker `<socket>.websocket.json`,
    /// written once its restore is done: a restore that ends behind the same
    /// socket then wakes too). Replaces an earlier watch of other files. A
    /// relative path is taken from the current directory, as `connect` takes it.
    public func watch(file path: String, companions: [String] = []) {
        let path = Self.absolute(path)
        let companions = companions.map(Self.absolute)
        let changed = state.withLock { state -> Bool in
            guard state.file != path || state.companions != companions else { return false }
            state.source?.cancel()
            state.source = nil
            state.folder = nil
            state.file = path
            state.companions = companions
            state.baseline = Self.identities(of: [path] + companions)
            return true
        }
        if changed { arm() }
    }

    /// Ends the watch: the vnode source is cancelled and no file is watched
    /// until the next ``watch(file:companions:)``. A pending ``fire()`` stays.
    /// A reader that is healthy, or that ended, keeps no watch (each entry
    /// change in the watched folder would wake the process).
    public func unwatch() {
        state.withLock { state in
            state.source?.cancel()
            state.source = nil
            state.folder = nil
            state.file = nil
            state.companions = []
            state.baseline = []
        }
    }

    /// Records the watched file's current identity and drops a pending
    /// event: call after a failed attempt, so only later changes wake. A watch
    /// that could not be armed before (no descriptor left), or that stopped
    /// above a folder that did not open (it may open now), is tried again.
    ///
    /// - Returns: Whether the file is there (and its identity), missing (and watched), or not watched.
    @discardableResult
    public func rebaseline() -> WatchedFile {
        let needsArm = state.withLock { state -> Bool in
            state.latched = nil
            state.baseline = state.file.map { Self.identities(of: [$0] + state.companions) } ?? []
            return state.file != nil && (state.source == nil || state.folder?.blocked != nil)
        }
        if needsArm { arm() }
        return state.withLock { state -> WatchedFile in
            guard state.file != nil else { return .unwatched }
            if let identity = state.baseline.first ?? nil { return .present(identity) }
            // A folder below the watch that did not open: the file can be made in it, and work
            // (connect needs only search permission), with no event at the watched folder.
            guard state.source != nil, state.folder?.blocked == nil else { return .unwatched }
            return .missing
        }
    }

    /// Waits for an event, or for `delay` when given. A pending event
    /// returns at once. `socket` false: a socket change does not wake this
    /// wait and a pending one is dropped (a crash loop, ``RetryPacer``).
    public func awaitWake(delay: Duration?, clock: any Clock<Duration>, socket: Bool = true) async -> Cause {
        await withTaskCancellationHandler {
            // A waiter dropped unresumed ends the wait as cancellation does.
            (try? await withOnceContinuation { (continuation: OnceContinuation<Cause, OnceContinuationError>) in
                let immediate = state.withLock { state -> Cause? in
                    if Task.isCancelled { return .cancelled }
                    if let latched = state.latched {
                        state.latched = nil
                        if latched == .event || socket { return latched }
                    }
                    state.waiter = continuation
                    state.waiterTakesSocket = socket
                    state.timer?.cancel()
                    state.timer = nil
                    if let delay {
                        // timer-class-allow: off main: the retry backoff only resumes the connect loop's waiter (thread-safe); no main-thread job
                        let timer = DemandTimer(owner: owner, clock: clock, ledger: ledger)
                        state.timer = timer
                        timer.schedule(after: delay) { [weak self] in self?.resume(.timer, latchIfIdle: false) }
                    }
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                } else {
                    probe.parked(delay)
                }
            }) ?? .cancelled
        } onCancel: {
            resume(.cancelled, latchIfIdle: false)
        }
    }

    private func resume(_ cause: Cause, latchIfIdle: Bool) {
        // A socket change that the waiting loop ignores (a crash loop) is dropped.
        let (waiter, ignored) = state.withLock { state -> (OnceContinuation<Cause, OnceContinuationError>?, Bool) in
            if cause == .socket, state.waiter != nil, !state.waiterTakesSocket { return (nil, true) }
            state.timer?.cancel()
            state.timer = nil
            guard let waiter = state.waiter else {
                if latchIfIdle, state.latched != .event { state.latched = cause }
                return (nil, false)
            }
            state.waiter = nil
            return (waiter, false)
        }
        if ignored { return }
        if cause == .event || cause == .socket { ledger.record(owner, reason: "event") }
        waiter?.resume(returning: cause)
    }

    /// Arms the vnode watch on the deepest folder on the watched file's path
    /// that exists and opens (the file's own folder once it exists), then
    /// checks once more: a deeper folder made while arming sends its events to
    /// a folder nobody watches (arm again, one level deeper), and the file
    /// itself made while arming sends none (fire now).
    private func arm() {
        while let file = state.withLock({ $0.file }) {
            guard let opened = Self.openNearestFolder(of: file) else {
                state.withLock { state in
                    guard state.file == file else { return }
                    state.source?.cancel()
                    state.source = nil
                    state.folder = nil
                }
                return
            }
            let folder = opened.folder
            let descriptor = opened.descriptor
            probe.folderChosen(folder.path)
            // DispatchSource for file watching: no Foundation async equivalent (idle-wakeups.md).
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                                   eventMask: [.write, .link, .delete, .rename], queue: queue)
            source.setEventHandler { [weak self] in self?.directoryChanged() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            let installed = state.withLock { state -> Bool in
                guard state.file == file else { return false }
                state.source?.cancel()
                state.source = source
                state.folder = folder
                return true
            }
            guard installed else {
                source.cancel()
                return
            }
            census.armed()
            if Self.folderMoved(toward: file, from: folder) { continue }
            fileChanged()
            return
        }
    }

    /// A vnode event on the watched folder: move the watch when the folder
    /// toward the file changed, else fire when the file changed.
    private func directoryChanged() {
        census.fired()
        let watched = state.withLock { state -> (file: String, folder: WatchedFolder)? in
            guard let file = state.file, let folder = state.folder else { return nil }
            return (file, folder)
        }
        guard let watched else { return }
        if Self.folderMoved(toward: watched.file, from: watched.folder) {
            ledger.record(owner, reason: "folder")
            arm()
        } else if !fileChanged() {
            // Another entry of the watched folder changed: the loop does not wake, the process did.
            ledger.record(owner, reason: "folder")
        }
    }

    /// Fires ``Cause/socket`` when the watched file's (or a companion's)
    /// identity differs from the baseline. Returns whether it did.
    @discardableResult
    private func fileChanged() -> Bool {
        let changed = state.withLock { state -> Bool in
            guard let file = state.file else { return false }
            let now = Self.identities(of: [file] + state.companions)
            guard now != state.baseline else { return false }
            state.baseline = now
            return true
        }
        if changed { resume(.socket, latchIfIdle: true) }
        return changed
    }

    /// `path` when absolute, else under the current directory (where `connect` resolves it).
    private static func absolute(_ path: String) -> String {
        path.hasPrefix("/") ? path : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path)
    }

    /// Opens, for events only, the deepest folder on `file`'s path that exists
    /// and opens (`/` at worst); nil when none opens (no descriptor left).
    private static func openNearestFolder(of file: String) -> (folder: WatchedFolder, descriptor: Int32)? {
        var blocked: Identity?
        for directory in folders(above: file) {
            if let identity = directoryIdentity(of: directory) {
                // SAFETY: open reads the NUL-terminated copy of `directory` Swift makes for the call.
                let descriptor = unsafe blockingOpen(directory, O_EVTONLY | O_CLOEXEC)
                if descriptor >= 0 {
                    return (WatchedFolder(path: directory, identity: identity, blocked: blocked), descriptor)
                }
                blocked = identity
            } else {
                blocked = nil
            }
        }
        return nil
    }

    /// `file`'s folder, then each folder above it, deepest first (up to `/` for an absolute path).
    private static func folders(above file: String) -> [String] {
        let components = ((file as NSString).deletingLastPathComponent as NSString).pathComponents
        return stride(from: components.count, through: 1, by: -1).map {
            NSString.path(withComponents: Array(components.prefix($0)))
        }
    }

    /// Whether the folder ``arm()`` would watch now differs from `folder`: it
    /// was removed or replaced (another identity at its path, so the open
    /// descriptor watches a dead folder), or the next folder down toward
    /// `file` now exists (other than the one that did not open).
    private static func folderMoved(toward file: String, from folder: WatchedFolder) -> Bool {
        guard directoryIdentity(of: folder.path) == folder.identity else { return true }
        guard let next = nextFolder(below: folder.path, toward: file),
              let identity = directoryIdentity(of: next) else { return false }
        return identity != folder.blocked
    }

    /// The folder one level below `folder` on the way to `file`'s folder; nil when `folder` is it.
    private static func nextFolder(below folder: String, toward file: String) -> String? {
        let target = ((file as NSString).deletingLastPathComponent as NSString).pathComponents
        let base = (folder as NSString).pathComponents
        guard target.count > base.count else { return nil }
        return NSString.path(withComponents: Array(target.prefix(base.count + 1)))
    }

    private static func identities(of paths: [String]) -> [Identity?] { paths.map(identity(of:)) }

    private static func identity(of path: String) -> Identity? {
        var info = stat()
        // SAFETY: stat reads the NUL-terminated copy of `path` made for the call and writes one struct stat into
        // `info`, a local live for the call.
        guard unsafe blockingStat(path, &info) == 0 else { return nil }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }

    private static func directoryIdentity(of path: String) -> Identity? {
        var info = stat()
        // SAFETY: as in identity(of:).
        guard unsafe blockingStat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }
}
