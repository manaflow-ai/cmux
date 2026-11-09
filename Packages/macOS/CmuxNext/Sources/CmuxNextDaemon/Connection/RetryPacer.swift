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
/// loop, only an explicit event does, one attempt each. The one exception is a
/// loop that starts its own peer (``keepsTrying``, the app's local daemon): it
/// keeps one attempt per backoff cap, because nothing sends an event when the
/// cause of a failed start goes away (a full disk, restore fuzz h2).
public struct RetryPolicy: Sendable {
    public var backoff: Backoff
    /// Failures after which retries wait for an event only.
    public var timedRetries: Int
    /// Failed attempts woken by a socket change after which socket changes
    /// stop waking the loop (a crash loop, cx-6so.7).
    public var socketRetries: Int
    /// Past `timedRetries` the loop keeps one timed attempt per `backoff.maximum` instead of
    /// waiting for an event only, and an explicit event starts the spacing over. For a loop that
    /// itself starts its peer (the app's local daemon, through `server ensure`): what made the
    /// start fail can end with no event at all (a full disk that has space again, restore fuzz h2).
    public var keepsTrying: Bool
    /// An explicit event that came while an attempt ran wakes the wait after it fails
    /// (``RetryWake/rebaseline(keepingEventsAfter:)``). For a loop with no timer left
    /// (``linkReconnect``): the link reporting connected during a failing attempt must not be lost.
    public var keepsEventsDuringAttempt: Bool
    /// Drops of a connection that each spend one token (``DropBudget``) instead of resetting the
    /// spacing when a connection opens or stays healthy: a peer that accepts and then closes at once
    /// gets at most `capacity` attempts before the next refill (cmuxterm-hq#7766). Nil: no budget.
    public var dropBudget: DropBudget?
    /// Retries of an attempt that failed while the link had no process to redial
    /// (``DaemonConnectionConfiguration/linkRunning``): the base's bounded timed retry, so a probe that
    /// failed while the machine booted still recovers. Nil: no such phase.
    public var bootstrap: BootstrapRetry?

    public init(initial: Duration, maximum: Duration, timedRetries: Int, socketRetries: Int = 3, keepsTrying: Bool = false,
                keepsEventsDuringAttempt: Bool = false, dropBudget: DropBudget? = nil, bootstrap: BootstrapRetry? = nil) {
        backoff = Backoff(initial: initial, maximum: maximum)
        self.timedRetries = timedRetries
        self.socketRetries = socketRetries
        self.keepsTrying = keepsTrying
        self.keepsEventsDuringAttempt = keepsEventsDuringAttempt
        self.dropBudget = dropBudget
        self.bootstrap = bootstrap
    }

    /// Daemon reconnect: 50 ms growing to 30 s, 10 timed attempts (~80 s).
    public static let reconnect = RetryPolicy(initial: .milliseconds(50), maximum: .seconds(30), timedRetries: 10)
    /// First connect to a daemon: 250 ms growing to 30 s, 10 timed attempts.
    public static let firstConnect = RetryPolicy(initial: .milliseconds(250), maximum: .seconds(30), timedRetries: 10)
    /// The app's own local daemon, which the reconnect starts (`server ensure`): as ``reconnect``,
    /// then one attempt every 30 s for as long as it fails (``keepsTrying``).
    public static let localReconnect = RetryPolicy(initial: .milliseconds(50), maximum: .seconds(30), timedRetries: 10, keepsTrying: true)
    /// The app's first connect to its local daemon: as ``firstConnect``, then one attempt every 30 s.
    public static let localFirstConnect = RetryPolicy(initial: .milliseconds(250), maximum: .seconds(30), timedRetries: 10, keepsTrying: true)
    /// A remote machine's first connect over a link whose own state machine redials (`cmux-tui remote
    /// connect`, cmuxterm-hq#7766): one attempt, then events only (the link reporting connected again,
    /// its process exiting, its socket replaced, app activation, a person's Reconnect). No timer: the
    /// link spends its own budget and deadlines, so a timed retry here would only stack dials on it.
    /// While the link has no process (it probes, installs or spawns) a failed attempt takes the
    /// ``BootstrapRetry/link`` timed retry instead.
    public static let linkFirstConnect = RetryPolicy(initial: .milliseconds(1), maximum: .milliseconds(1), timedRetries: 0,
                                                     keepsEventsDuringAttempt: true, bootstrap: .link)
    /// ``linkFirstConnect`` for a connection that dropped: each drop spends one token of a budget that
    /// lives across connections (3 tokens, 1 back every 10 s) for one attempt after a jittered backoff
    /// (50 ms growing to 2 s while drops come faster than the refill); an empty budget waits for the
    /// next token or an event. A failed attempt waits for an event only.
    public static let linkReconnect = RetryPolicy(initial: .milliseconds(50), maximum: .seconds(2), timedRetries: 1,
                                                  keepsEventsDuringAttempt: true,
                                                  dropBudget: DropBudget(capacity: 3, refill: .seconds(10)), bootstrap: .link)
    /// A failing store snapshot while connected: 100 ms growing to 10 s, 8 attempts.
    public static let resync = RetryPolicy(initial: .milliseconds(100), maximum: .seconds(10), timedRetries: 8)
}

/// The timed retry of an attempt that failed while a link had no process (``RetryPolicy/bootstrap``).
public struct BootstrapRetry: Sendable {
    public var backoff: Backoff
    public var timedRetries: Int

    public init(initial: Duration, maximum: Duration, timedRetries: Int) {
        backoff = Backoff(initial: initial, maximum: maximum)
        self.timedRetries = timedRetries
    }

    /// As ``RetryPolicy/firstConnect``: 250 ms growing to 30 s, 10 timed attempts, then events only.
    public static let link = BootstrapRetry(initial: .milliseconds(250), maximum: .seconds(30), timedRetries: 10)
}

/// A token bucket for reconnects after drops (``RetryPolicy/dropBudget``): `capacity` tokens, one
/// back every `refill`. It lives as long as its pacer, across connections, so neither a handshake nor
/// a connection that stays up refills it; only time and an explicit reconnect (``fill()``) do.
public struct DropBudget: Sendable, Equatable {
    public let capacity: Int
    public let refill: Duration
    public private(set) var tokens: Int
    /// When the token being refilled started; meaningless while full.
    private var since: ContinuousClock.Instant?

    public init(capacity: Int, refill: Duration) {
        self.capacity = capacity
        self.refill = refill
        tokens = capacity
    }

    /// Whether the budget is full at `now`: no drop spent a token for at least a refill.
    public mutating func isFull(at now: ContinuousClock.Instant) -> Bool {
        accrue(at: now)
        return tokens >= capacity
    }

    /// Spends one token and returns nil, or returns how long until the next token when it is empty.
    public mutating func take(at now: ContinuousClock.Instant) -> Duration? {
        accrue(at: now)
        if tokens > 0 {
            if tokens == capacity { since = now }
            tokens -= 1
            return nil
        }
        let start = since ?? now
        return max(.zero, refill - (now - start))
    }

    /// An explicit reconnect: every token back.
    public mutating func fill() {
        tokens = capacity
        since = nil
    }

    private mutating func accrue(at now: ContinuousClock.Instant) {
        guard tokens < capacity, var start = since, refill > .zero else { return }
        // At most `capacity` steps: each one is a token back.
        while tokens < capacity, start + refill <= now {
            tokens += 1
            start += refill
        }
        since = tokens == capacity ? nil : start
    }
}

/// One retry loop's pacing state: a single ``Backoff`` across consecutive
/// failures, reset only after a success that stayed healthy (or, under a
/// ``RetryPolicy/dropBudget``, spent per drop and never reset by a connection).
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
    /// Spacing of busy refusals under a link policy (``RetryPolicy/keepsEventsDuringAttempt``), whose own
    /// backoff is 1 ms: from 50 ms toward ``busyRetryCap``, as the timed policies space them.
    private var busyBackoff = Backoff(initial: .milliseconds(50), maximum: RetryPacer.busyRetryCap)
    /// The longest spacing after a busy refusal: the daemon is up and frees a slot
    /// as soon as one of its connections ends.
    public static let busyRetryCap: Duration = .seconds(1)
    /// Tokens for attempts after drops (``RetryPolicy/dropBudget``); kept by ``reset()``.
    public private(set) var dropBudget: DropBudget?
    /// A drop happened and its attempt has not run yet (``noteDrop()``).
    private var dropPending = false
    /// The current wait is for the next token of an empty ``dropBudget``.
    public private(set) var waitsForToken = false

    /// Consecutive failures while the link had no process (``failedBeforeLink()``).
    public private(set) var bootstrapFailures = 0
    private var bootstrapBackoff: Backoff?

    public init(_ policy: RetryPolicy) {
        self.policy = policy
        backoff = policy.backoff
        dropBudget = policy.dropBudget
        bootstrapBackoff = policy.bootstrap?.backoff
    }

    /// Notes a failure while the link had no process and returns the spacing before the next attempt
    /// (``RetryPolicy/bootstrap``), or nil once its timed retries are spent. Without a bootstrap retry,
    /// as ``failed()``.
    public mutating func failedBeforeLink() -> Duration? {
        guard let bootstrap = policy.bootstrap, var spacing = bootstrapBackoff else { return failed() }
        busyRefusal = false
        wokeBySocket = false
        bootstrapFailures += 1
        defer { bootstrapBackoff = spacing }
        return bootstrapFailures > bootstrap.timedRetries ? nil : spacing.next()
    }

    /// Spacing before the next attempt after a failed one: ``failedBeforeLink()`` when `linkRunning`
    /// says the link had no process, else ``failed()``.
    public mutating func failed(linkRunning: (@Sendable () -> Bool)?) -> Duration? {
        // A drop's attempt spends its token first (``noteDrop()``).
        if !dropPending, policy.bootstrap != nil, let linkRunning, !linkRunning() { return failedBeforeLink() }
        return failed()
    }

    /// The connection dropped: under a ``RetryPolicy/dropBudget`` the next ``failed()`` spends a token
    /// for the attempt (or waits for the next one) instead of counting a failed attempt.
    public mutating func noteDrop() {
        dropPending = dropBudget != nil
    }

    /// An explicit reconnect (a person's Reconnect): the drop budget is full again.
    public mutating func refillDropBudget() {
        dropBudget?.fill()
    }

    /// The timed-retry budget is spent: wait for an event only (never for a ``RetryPolicy/keepsTrying`` loop).
    public var isExhausted: Bool { failures >= policy.timedRetries && !policy.keepsTrying }

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
        busyBackoff.reset()
        bootstrapFailures = 0
        bootstrapBackoff?.reset()
    }

    /// Notes one failure and returns the spacing before the next attempt,
    /// or nil when the budget is spent (wait for an event only).
    public mutating func failed() -> Duration? {
        // The link's process exists again: a later bootstrap starts its spacing over.
        bootstrapFailures = 0
        bootstrapBackoff?.reset()
        if busyRefusal {
            busyRefusal = false
            wokeBySocket = false
            if policy.keepsEventsDuringAttempt { return busyBackoff.next() }
            return min(backoff.next(), Self.busyRetryCap)
        }
        if dropPending, var budget = dropBudget {
            // A drop: one attempt per token, spaced by the backoff while drops come faster than the refill.
            let now = ContinuousClock.now
            if budget.isFull(at: now) { backoff.reset() }
            let wait = budget.take(at: now)
            dropBudget = budget
            guard let wait else {
                dropPending = false
                failures = 0
                wokeBySocket = false
                return backoff.next()
            }
            waitsForToken = true
            return wait
        }
        if dropBudget != nil {
            // A failed attempt after a drop's: the link redials, so wait for its event only.
            failures += 1
            if wokeBySocket { socketFailures += 1 }
            wokeBySocket = false
            return nil
        }
        failures += 1
        if wokeBySocket { socketFailures += 1 }
        wokeBySocket = false
        // Past the budget a loop that keeps trying stays at the backoff's cap (`Backoff.next` caps it).
        return failures > policy.timedRetries && !policy.keepsTrying ? nil : backoff.next()
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

    /// Notes what woke the wait before the next attempt. An explicit event (app activation, Retry
    /// Now, Restart cmux-tui) starts a ``RetryPolicy/keepsTrying`` loop's spacing over; the
    /// crash-loop count stays, so a daemon that dies on every connect still stops socket wakes.
    public mutating func woke(_ cause: RetryWake.Cause) {
        if waitsForToken {
            waitsForToken = false
            // The next token is due: the drop's attempt spends it. An event or socket change
            // attempts at once without one.
            if cause == .timer { _ = dropBudget?.take(at: .now) }
            dropPending = false
            failures = 0
        }
        wokeBySocket = cause == .socket
        if cause == .event, policy.keepsTrying {
            failures = 0
            backoff.reset()
        }
    }
}

extension RetryPacer {
    /// After a failure: rebaselines `wake`, then waits for the backoff
    /// spacing (cut short by an event) or, once the budget is spent, for an
    /// event only; in a crash loop a socket change no longer counts.
    /// Returns false when cancelled.
    /// `mark`: ``RetryWake/eventMark`` taken before the failed attempt; an event since then is kept
    /// when the policy ``RetryPolicy/keepsEventsDuringAttempt``.
    public mutating func waitAfterFailure(wake: RetryWake, clock: any Clock<Duration>, since mark: UInt64? = nil,
                                          linkRunning: (@Sendable () -> Bool)? = nil) async -> Bool {
        wake.rebaseline(keepingEventsAfter: policy.keepsEventsDuringAttempt ? mark : nil)
        let delay = failed(linkRunning: linkRunning)
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
