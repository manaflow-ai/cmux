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

    /// Notes a failure while the socket is missing: it spends no timed
    /// retry (no timed attempt can succeed before the socket appears), but a
    /// socket that a socket change brought and that is gone again counts
    /// toward the crash-loop limit.
    public mutating func failedWhileMissing() {
        if wokeBySocket { socketFailures += 1 }
        wokeBySocket = false
    }

    /// Notes what woke the wait before the next attempt.
    public mutating func woke(_ cause: RetryWake.Cause) {
        wokeBySocket = cause == .socket
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

    /// ``waitAfterFailure(wake:clock:)`` for a client of a daemon that it does
    /// not start itself (the Feed's acpmux mailbox reader): while the watched
    /// socket is missing and its folder chain is watched, no timed attempt can
    /// succeed, so the wait arms no timer and ends only when the socket
    /// appears or an explicit event fires. The timed budget is kept for a
    /// socket that exists but refuses (a crashed daemon's stale socket, a
    /// handoff). A path that cannot be watched (no descriptor left) falls back
    /// to the timed wait. Returns false when cancelled.
    public mutating func waitForPeerAfterFailure(wake: RetryWake, clock: any Clock<Duration>) async -> Bool {
        let delay: Duration?
        switch wake.rebaseline() {
        case .missing:
            failedWhileMissing()
            delay = nil
        case .present, .unwatched:
            delay = failed()
        }
        let cause = await wake.awaitWake(delay: delay, clock: clock, socket: wakesOnSocket)
        woke(cause)
        return cause != .cancelled
    }
}
