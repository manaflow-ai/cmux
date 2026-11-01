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
    /// The socket whose refusals spent the timed retries
    /// (``waitForPeerAfterFailure(wake:clock:)``); nil until one refused.
    private var budgetSocket: RetryWake.Identity?
    /// The last attempt was refused at the daemon's connection limit (``refusedBusy()``).
    private var busyRefusal = false
    /// The longest spacing after a busy refusal: the daemon is up and frees a slot
    /// as soon as one of its connections ends.
    public static let busyRetryCap: Duration = .seconds(1)

    public init(_ policy: RetryPolicy) {
        self.policy = policy
        backoff = policy.backoff
    }

    /// The timed-retry budget is spent: wait for an event only.
    public var isExhausted: Bool { failures >= policy.timedRetries }

    /// The next wait arms no timer: the budget is spent and the last attempt was not a busy
    /// refusal (``refusedBusy()``), whose daemon is alive and keeps a timed retry.
    public var waitsForEventOnly: Bool { isExhausted && !busyRefusal }

    /// A socket change may wake the next wait: false in a crash loop.
    public var wakesOnSocket: Bool { socketFailures < policy.socketRetries }

    public mutating func reset() {
        failures = 0
        socketFailures = 0
        wokeBySocket = false
        budgetSocket = nil
        busyRefusal = false
        backoff.reset()
    }

    /// Notes one failure and returns the spacing before the next attempt,
    /// or nil when the budget is spent (wait for an event only).
    public mutating func failed() -> Duration? {
        if busyRefusal {
            busyRefusal = false
            wokeBySocket = false
            return min(backoff.next(), Self.busyRetryCap)
        }
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

    /// Notes a failure while the socket `socket` exists (it refused, or its
    /// daemon answered with an error) and returns the spacing before the next
    /// attempt, or nil when the budget is spent.
    ///
    /// The timed retries belong to one socket. A socket other than the one
    /// that spent them (its daemon was restarted) gets timed retries of its
    /// own, because its change can come while an attempt runs, before the
    /// rebaseline that follows it, and then wakes nothing: the new daemon was
    /// binding, or answered while it started. Each such renewal counts as a
    /// failure a socket change brought, so a daemon that keeps replacing its
    /// socket gets at most `socketRetries` renewals until a success resets
    /// the pacer.
    public mutating func failed(at socket: RetryWake.Identity) -> Duration? {
        if budgetSocket == nil {
            budgetSocket = socket
        } else if budgetSocket != socket, wakesOnSocket {
            budgetSocket = socket
            failures = 0
            backoff.reset()
            wokeBySocket = true
        }
        return failed()
    }

    /// The attempt was refused at the daemon's connection limit (`server.busy`): the
    /// daemon is alive and answering, so the failure spends no timed retry and the next
    /// spacing is at most ``busyRetryCap``. Past the budget the loop would wait for an
    /// event only, and a busy daemon behind the same socket fires none: the app stayed
    /// "not connected" (every split snapped back) while CLI clients took each freed slot.
    public mutating func refusedBusy() {
        busyRefusal = true
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
    /// handoff), and renewed for a socket that replaced it
    /// (``failed(at:)``). A path that cannot be watched (no descriptor left, a
    /// folder on the way that does not open) falls back to the timed wait.
    /// Returns false when cancelled.
    public mutating func waitForPeerAfterFailure(wake: RetryWake, clock: any Clock<Duration>) async -> Bool {
        let delay: Duration?
        switch wake.rebaseline() {
        case .missing:
            failedWhileMissing()
            delay = nil
        case let .present(socket):
            delay = failed(at: socket)
        case .unwatched:
            delay = failed()
        }
        let cause = await wake.awaitWake(delay: delay, clock: clock, socket: wakesOnSocket)
        woke(cause)
        return cause != .cancelled
    }
}
