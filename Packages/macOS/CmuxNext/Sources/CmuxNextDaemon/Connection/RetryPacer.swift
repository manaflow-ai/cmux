public import CmuxNextWakeups
import Darwin
import Dispatch
import Foundation
import CmuxNextCompat

/// How a retry loop spaces attempts after real failures
/// (plans/cmux-next/idle-wakeups.md). Attempts are spaced by a capped,
/// jittered ``Backoff`` that keeps growing across consecutive failures; after
/// `timedRetries` failures no timer is armed at all and the loop waits for a
/// ``RetryWake`` event (the daemon socket changed, the network returned, the
/// app became active). So a dead peer costs a bounded number of attempts,
/// never a periodic wakeup. A daemon that is relaunched and dies on connect
/// makes a new socket each time; after `socketRetries` such failed attempts
/// (until a connection stays healthy) a socket change no longer wakes the
/// loop, only an explicit event does, one attempt each.
public struct RetryPolicy: Sendable {
    public var backoff: Backoff
    /// Failures after which retries wait for an event only.
    public var timedRetries: Int
    /// Failed attempts woken by a socket change after which socket changes
    /// stop waking the loop (a crash loop, cx-6so.7).
    public var socketRetries: Int

    public init(initial: Duration, maximum: Duration, timedRetries: Int, socketRetries: Int = 3) {
        backoff = Backoff(initial: initial, maximum: maximum)
        self.timedRetries = timedRetries
        self.socketRetries = socketRetries
    }

    /// Daemon reconnect: 50 ms growing to 30 s, 10 timed attempts (~80 s).
    public static let reconnect = RetryPolicy(initial: .milliseconds(50), maximum: .seconds(30), timedRetries: 10)
    /// First connect to a daemon: 250 ms growing to 30 s, 10 timed attempts.
    public static let firstConnect = RetryPolicy(initial: .milliseconds(250), maximum: .seconds(30), timedRetries: 10)
    /// A failing store snapshot while connected: 100 ms growing to 10 s, 8 attempts.
    public static let resync = RetryPolicy(initial: .milliseconds(100), maximum: .seconds(10), timedRetries: 8)
}

/// One retry loop's pacing state: a single ``Backoff`` across consecutive
/// failures, reset only after a success that stayed healthy.
public struct RetryPacer: Sendable {
    public let policy: RetryPolicy
    private var backoff: Backoff
    public private(set) var failures = 0
    /// Failed attempts since the last reset that a socket change woke.
    public private(set) var socketFailures = 0
    private var wokeBySocket = false

    public init(_ policy: RetryPolicy) {
        self.policy = policy
        backoff = policy.backoff
    }

    /// The timed-retry budget is spent: wait for an event only.
    public var isExhausted: Bool { failures >= policy.timedRetries }

    /// A socket change may wake the next wait: false in a crash loop.
    public var wakesOnSocket: Bool { socketFailures < policy.socketRetries }

    public mutating func reset() {
        failures = 0
        socketFailures = 0
        wokeBySocket = false
        backoff.reset()
    }

    /// Notes one failure and returns the spacing before the next attempt,
    /// or nil when the budget is spent (wait for an event only).
    public mutating func failed() -> Duration? {
        failures += 1
        if wokeBySocket { socketFailures += 1 }
        wokeBySocket = false
        return failures > policy.timedRetries ? nil : backoff.next()
    }

    /// Notes what woke the wait before the next attempt.
    public mutating func woke(_ cause: RetryWake.Cause) {
        wokeBySocket = cause == .socket
    }
}

/// An event that can make a retry succeed. Fired by callers (network path
/// change, app activation) and by a kernel vnode watch on a socket file's
/// directory (``watch(file:)``): the watch fires only when the file's
/// identity differs from the one recorded after the last failed attempt
/// (``rebaseline()``), so the loop's own attempts (a `server ensure` that
/// recreates the socket) never wake it again.
public final class RetryWake: Sendable {
    public enum Cause: Sendable, Equatable {
        /// ``fire()``: an explicit event (app activation, network, a reconnect action).
        case event
        /// The watched socket changed (``watch(file:companions:)``).
        case socket
        case timer
        case cancelled
    }

    public let owner: String
    private let ledger: WakeupLedger
    private let queue = DispatchQueue(label: "com.cmuxterm.next.retry-wake")
    private let state = Mutex<State>(State())

    private struct Identity: Equatable {
        var device: dev_t
        var inode: ino_t
    }

    private struct State {
        /// An event that came with no waiter (`.event` wins over `.socket`).
        var latched: Cause?
        var waiter: CheckedContinuation<Cause, Never>?
        /// The waiter wakes on a socket change too.
        var waiterTakesSocket = true
        var timer: DemandTimer?
        var file: String?
        /// Files beside `file` that wake too (a daemon's ready marker).
        var companions: [String] = []
        var baseline: [Identity?] = []
        var source: (any DispatchSourceFileSystemObject)?
    }

    public init(owner: String, ledger: WakeupLedger = .shared) {
        self.owner = owner
        self.ledger = ledger
    }

    deinit {
        state.withLock { $0.source?.cancel() }
    }

    /// Something changed that may let a retry succeed.
    public func fire() {
        resume(.event, latchIfIdle: true)
    }

    /// Watches `path`'s directory; a change of `path` itself (created,
    /// removed, replaced) fires, and so does a change of any of `companions`
    /// (files in the same directory, such as the daemon's ready marker
    /// `<socket>.websocket.json`, written once its restore is done: a restore
    /// that ends behind the same socket then wakes too). Replaces an earlier
    /// watch of other files.
    public func watch(file path: String, companions: [String] = []) {
        let directory = (path as NSString).deletingLastPathComponent
        let changed = state.withLock { state -> Bool in
            guard state.file != path || state.companions != companions else { return false }
            state.source?.cancel()
            state.source = nil
            state.file = path
            state.companions = companions
            state.baseline = Self.identities(of: [path] + companions)
            return true
        }
        guard changed else { return }
        let descriptor = open(directory, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .link, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self] in self?.directoryChanged() }
        source.setCancelHandler { close(descriptor) }
        let installed = state.withLock { state -> Bool in
            guard state.file == path, state.source == nil else { return false }
            state.source = source
            return true
        }
        if installed { source.resume() } else { close(descriptor) }
    }

    /// Records the watched file's current identity and drops a pending
    /// event: call after a failed attempt, so only later changes wake.
    public func rebaseline() {
        state.withLock { state in
            state.latched = nil
            state.baseline = state.file.map { Self.identities(of: [$0] + state.companions) } ?? []
        }
    }

    /// Waits for an event, or for `delay` when given. A pending event
    /// returns at once. `socket` false: a socket change does not wake this
    /// wait and a pending one is dropped (a crash loop, ``RetryPacer``).
    public func awaitWake(delay: Duration?, clock: any Clock<Duration>, socket: Bool = true) async -> Cause {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Cause, Never>) in
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
                        let timer = DemandTimer(owner: owner, clock: clock, ledger: ledger)
                        state.timer = timer
                        timer.schedule(after: delay) { [weak self] in self?.resume(.timer, latchIfIdle: false) }
                    }
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            resume(.cancelled, latchIfIdle: false)
        }
    }

    private func resume(_ cause: Cause, latchIfIdle: Bool) {
        // A socket change that the waiting loop ignores (a crash loop) is dropped.
        let (waiter, ignored) = state.withLock { state -> (CheckedContinuation<Cause, Never>?, Bool) in
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

    private func directoryChanged() {
        let changed = state.withLock { state -> Bool in
            guard let file = state.file else { return false }
            let now = Self.identities(of: [file] + state.companions)
            guard now != state.baseline else { return false }
            state.baseline = now
            return true
        }
        if changed { resume(.socket, latchIfIdle: true) }
    }

    private static func identities(of paths: [String]) -> [Identity?] { paths.map(identity(of:)) }

    private static func identity(of path: String) -> Identity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }
}

extension RetryPacer {
    /// After a failure: rebaselines `wake`, then waits for the backoff
    /// spacing (cut short by an event) or, once the budget is spent, for an
    /// event only; in a crash loop a socket change no longer counts.
    /// Returns false when cancelled.
    public mutating func waitAfterFailure(wake: RetryWake, clock: any Clock<Duration>) async -> Bool {
        wake.rebaseline()
        let delay = failed()
        let cause = await wake.awaitWake(delay: delay, clock: clock, socket: wakesOnSocket)
        woke(cause)
        return cause != .cancelled
    }
}
