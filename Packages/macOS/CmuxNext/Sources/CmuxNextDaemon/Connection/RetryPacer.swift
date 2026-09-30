public import CmuxNextWakeups
import Darwin
import Dispatch
import Foundation
import Synchronization

/// How a retry loop spaces attempts after real failures
/// (plans/cmux-next/idle-wakeups.md). Attempts are spaced by a capped,
/// jittered ``Backoff`` that keeps growing across consecutive failures; after
/// `timedRetries` failures no timer is armed at all and the loop waits for a
/// ``RetryWake`` event (the daemon socket changed, the network returned, the
/// app became active). So a dead peer costs a bounded number of attempts,
/// never a periodic wakeup.
public struct RetryPolicy: Sendable {
    public var backoff: Backoff
    /// Failures after which retries wait for an event only.
    public var timedRetries: Int

    public init(initial: Duration, maximum: Duration, timedRetries: Int) {
        backoff = Backoff(initial: initial, maximum: maximum)
        self.timedRetries = timedRetries
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

    public init(_ policy: RetryPolicy) {
        self.policy = policy
        backoff = policy.backoff
    }

    /// The timed-retry budget is spent: wait for an event only.
    public var isExhausted: Bool { failures >= policy.timedRetries }

    public mutating func reset() {
        failures = 0
        backoff.reset()
    }

    /// Notes one failure and returns the spacing before the next attempt,
    /// or nil when the budget is spent (wait for an event only).
    public mutating func failed() -> Duration? {
        failures += 1
        return failures > policy.timedRetries ? nil : backoff.next()
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
        case event
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
        var latched = false
        var waiter: CheckedContinuation<Cause, Never>?
        var timer: DemandTimer?
        var file: String?
        var baseline: Identity?
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
    /// removed, replaced) fires. Replaces an earlier watch of another file.
    public func watch(file path: String) {
        let directory = (path as NSString).deletingLastPathComponent
        let changed = state.withLock { state -> Bool in
            guard state.file != path else { return false }
            state.source?.cancel()
            state.source = nil
            state.file = path
            state.baseline = Self.identity(of: path)
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
            state.latched = false
            state.baseline = state.file.flatMap(Self.identity(of:))
        }
    }

    /// Waits for an event, or for `delay` when given. A pending event
    /// returns at once.
    public func wait(delay: Duration?, clock: any Clock<Duration>) async -> Cause {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Cause, Never>) in
                let immediate = state.withLock { state -> Cause? in
                    if Task.isCancelled { return .cancelled }
                    if state.latched {
                        state.latched = false
                        return .event
                    }
                    state.waiter = continuation
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
        let waiter = state.withLock { state -> CheckedContinuation<Cause, Never>? in
            state.timer?.cancel()
            state.timer = nil
            guard let waiter = state.waiter else {
                if latchIfIdle { state.latched = true }
                return nil
            }
            state.waiter = nil
            return waiter
        }
        if cause == .event { ledger.record(owner, reason: "event") }
        waiter?.resume(returning: cause)
    }

    private func directoryChanged() {
        let changed = state.withLock { state -> Bool in
            guard let file = state.file else { return false }
            let now = Self.identity(of: file)
            guard now != state.baseline else { return false }
            state.baseline = now
            return true
        }
        if changed { fire() }
    }

    private static func identity(of path: String) -> Identity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }
}

extension RetryPacer {
    /// After a failure: rebaselines `wake`, then waits for the backoff
    /// spacing (cut short by an event) or, once the budget is spent, for an
    /// event only. Returns false when cancelled.
    public mutating func waitAfterFailure(wake: RetryWake, clock: any Clock<Duration>) async -> Bool {
        wake.rebaseline()
        let delay = failed()
        return await wake.wait(delay: delay, clock: clock) != .cancelled
    }
}
