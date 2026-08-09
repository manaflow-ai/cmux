import Foundation

/// (B) ExternalHover — the lock-protected coordinator around one surface's
/// `ExternalHoverMailbox`, and the only place the mailbox lock is taken.
///
/// Lock-section discipline (review checklist): the mailbox lock section
/// below never does main-thread dispatch, filesystem probes, or any other
/// Ghostty API call — the ONE exception is `setPendingThenCallSetter`,
/// which intentionally holds the lock continuously through the caller's
/// `setterCall` closure (the Ghostty setter call itself) precisely so that
/// Ghostty's own synchronous callback path can never observe `pending`
/// before it is published here (the B0-6 lock-ordering fix: mailbox ->
/// Ghostty setter, held continuously, unlocked only after). Every other
/// method here only mutates the mailbox value and computes what to
/// schedule; the actual `scheduler` call (main-thread dispatch) and
/// `project` call (the view mutation) always happen AFTER the lock is
/// released.
///
/// This class is plain value-holding state behind a lock, never an
/// `ObservableObject` and never referenced from a SwiftUI `body` — it is
/// meant to be held by a surface-scoped, non-observable owner (the
/// AppKit-side terminal surface), matching `Surface.zig`'s renderer-mutex
/// discipline on the Ghostty side.
public final class ExternalHoverOwnerCoordinator: @unchecked Sendable {
    public typealias MainTask = () -> Void
    public typealias Scheduler = (@escaping MainTask) -> Void
    public typealias Project = (ExternalHoverMailbox.Entry?) -> Void

    private let lock = NSLock()
    private var mailbox = ExternalHoverMailbox()

    private let scheduler: Scheduler
    private let project: Project

    /// - Parameters:
    ///   - scheduler: Enqueues a main-thread task. Production callers pass
    ///     `{ DispatchQueue.main.async(execute: $0) }`; tests pass a
    ///     deterministic seam (e.g. appending to an array of pending tasks
    ///     the test drains in whatever order it wants to exercise), never a
    ///     real-time `sleep`.
    ///   - project: Applies an accepted-owner snapshot (or `nil`) to the
    ///     view. Always called from a task the `scheduler` ran, never
    ///     synchronously from any of this type's own methods.
    public init(scheduler: @escaping Scheduler, project: @escaping Project) {
        self.scheduler = scheduler
        self.project = project
    }

    /// Read-only snapshot for tests and diagnostics; takes the lock briefly.
    public var currentMailbox: ExternalHoverMailbox {
        lock.lock()
        defer { lock.unlock() }
        return mailbox
    }

    /// Calls `setterCall` — the actual Ghostty setter — while holding the
    /// mailbox lock, and only on success records the resulting pending
    /// candidate in that SAME critical section. This is the fix for the
    /// (B) wiring review's blocking finding: the real
    /// `ghostty_surface_set_external_link_hover` mints its activation token
    /// as an OUT PARAMETER — the caller never knows the token before the
    /// call returns, so `setterCall` must itself perform the C call and
    /// hand back whatever token it minted (or `nil`/`.zero` on failure).
    /// Closing the setter call and the pending-write inside one lock
    /// section is what prevents the race where Ghostty's callback for this
    /// exact token could otherwise arrive before `pending` is published.
    ///
    /// On failure (`setterCall` returns `nil` or `.zero`), this does
    /// nothing: no pending write happens, and any existing pending entry is
    /// left untouched — a failed setter call must never clobber a still-
    /// live earlier candidate.
    ///
    /// `setterCall` must never call back into any other method on this
    /// coordinator (or otherwise try to take this same lock) — `NSLock` is
    /// not reentrant, and the real Ghostty setter call this wraps returns
    /// without synchronously calling back into cmux, so a real caller never
    /// needs to.
    @discardableResult
    public func callSetterAndRecordPending(
        event: UInt64,
        path: String,
        setterCall: () -> HoverActivationTokenValue?
    ) -> HoverActivationTokenValue? {
        lock.lock()
        defer { lock.unlock() }
        guard let token = setterCall(), token != .zero else { return nil }
        mailbox.setPending(.init(event: event, token: token, path: path))
        return token
    }

    /// The ONLY entry point Ghostty's `external_link_hover` action callback
    /// should call — it carries just `{token, active}`, never a path or
    /// event id, so this is the sole place that ever turns a bare token
    /// into an owner mutation.
    ///
    /// `active == true`: promotes `pending` to accepted owner ONLY if
    /// `pending.token == token` — the callback has no other way to prove
    /// which candidate this ack answers, so a mismatched token (a stale ack
    /// for a candidate `pending` has already moved past, or a foreign
    /// token) is silently rejected: no mutation, no projection. This is
    /// what the (B) wiring review's blocking finding required — the old
    /// `acceptActive(_ entry:)` accepted an arbitrary caller-supplied
    /// `Entry` with no such check.
    ///
    /// `active == false`: idempotent per final-spec (see `inactive`
    /// below), and additionally clears `pending` if `pending.token ==
    /// token` — a setter call whose activation was rejected before ever
    /// becoming owner must not be resurrectable later.
    ///
    /// (B) wiring review Blocking 5: returns whether this call committed
    /// the host into logical acceptance, matching final-spec's
    /// `performAction == true` contract exactly — the caller (the
    /// `GHOSTTY_ACTION_EXTERNAL_LINK_HOVER` action handler) must return
    /// this value verbatim to Ghostty's ack reducer.
    /// - `active == true` and `token` matches `pending`: commits, `true`.
    /// - `active == true` and `token` does NOT match `pending`: rejected,
    ///   `false` — the core must not treat this as published.
    /// - `active == false`: always `true` (idempotent per final-spec —
    ///   the postcondition "`token` is not owner" holds either way).
    @discardableResult
    public func receiveTransition(token: HoverActivationTokenValue, active: Bool) -> Bool {
        if active {
            return acceptPendingIfTokenMatches(token)
        }
        clearPendingIfTokenMatches(token)
        return inactive(token: token)
    }

    @discardableResult
    private func acceptPendingIfTokenMatches(_ token: HoverActivationTokenValue) -> Bool {
        var revision: UInt64?
        var matched = false
        lock.lock()
        if let pendingEntry = mailbox.pending, pendingEntry.token == token {
            mailbox.acceptActive(pendingEntry)
            revision = mailbox.ownerRevision
            matched = true
        }
        lock.unlock()
        if let revision {
            enqueueProjection(atRevision: revision)
        }
        return matched
    }

    private func clearPendingIfTokenMatches(_ token: HoverActivationTokenValue) {
        lock.lock()
        if mailbox.pending?.token == token {
            mailbox.clearPending()
        }
        lock.unlock()
    }

    /// Ghostty's ack arrived with `active == false` (or an error/timeout)
    /// for `token`. Idempotent per final-spec: if `token` is not the
    /// current owner (already replaced by a newer accept, or already
    /// cleared), the postcondition already holds and this returns `true`
    /// without touching whatever newer owner is installed and without
    /// scheduling a projection (nothing observable changed) — this is what
    /// lets a stale core-side inactive retry terminate instead of racing a
    /// newer accept. Only clears and schedules a projection when `token`
    /// really was the current owner.
    @discardableResult
    private func inactive(token: HoverActivationTokenValue) -> Bool {
        var didClear = false
        let revision: UInt64 = {
            lock.lock()
            defer { lock.unlock() }
            let wasOwner = mailbox.acceptedOwner?.token == token
            _ = mailbox.inactive(token: token)
            didClear = wasOwner
            return mailbox.ownerRevision
        }()
        if didClear {
            enqueueProjection(atRevision: revision)
        }
        return true
    }

    /// (B) wiring review Blocking 7 — the ONE shared-withdrawal entry
    /// point for every host-initiated clear: resolver nil, setter
    /// rejection, Cmd release, selection/remote/ineligible, cwd change,
    /// visibility loss, and surface replacement/teardown all route here
    /// (via the actor's `withdrawCurrentCandidate`, not by calling this
    /// directly with ad-hoc surrounding logic).
    ///
    /// Clears BOTH `pending` and the accepted owner in the SAME mailbox
    /// critical section — never two separate lock acquisitions (calling
    /// `clearPending` and a separate `clearOwnerUnconditionally` back to
    /// back could let an accept land in the gap between them and be
    /// silently dropped by a clear that no longer matches anything by the
    /// time it runs). Returns the accepted owner that was cleared, if any,
    /// so the caller can read its `activationToken` to release the
    /// matching Ghostty-side override — this method itself never calls any
    /// Ghostty API. Schedules a projection of `nil` only if there actually
    /// was an accepted owner to clear.
    @discardableResult
    public func withdrawUnconditionally() -> ExternalHoverMailbox.Entry? {
        var removed: ExternalHoverMailbox.Entry?
        let revision: UInt64 = {
            lock.lock()
            defer { lock.unlock() }
            mailbox.clearPending()
            removed = mailbox.clearOwnerUnconditionally()
            return mailbox.ownerRevision
        }()
        if removed != nil {
            enqueueProjection(atRevision: revision)
        }
        return removed
    }

    /// Surface teardown: tombstones the mailbox (advances `ownerRevision`
    /// unconditionally) so every already-queued projection task, and this
    /// one, resolve as no-ops once run — see `runProjectionIfCurrent`.
    public func teardown() {
        let revision: UInt64 = {
            lock.lock()
            defer { lock.unlock() }
            mailbox.teardown()
            return mailbox.ownerRevision
        }()
        enqueueProjection(atRevision: revision)
    }

    private func enqueueProjection(atRevision revision: UInt64) {
        scheduler { [weak self] in
            self?.runProjectionIfCurrent(revision)
        }
    }

    /// Runs on the main thread (per `scheduler`). Re-checks the mailbox's
    /// *current* `ownerRevision` against the revision captured at mutation
    /// time before applying anything — never re-reads `pending`, never
    /// calls any Ghostty API. A mismatch means a newer owner mutation (or a
    /// teardown) has already superseded this task, so it silently does
    /// nothing: a stale event's task can never resurrect display after a
    /// newer event.
    private func runProjectionIfCurrent(_ revision: UInt64) {
        let outcome: ExternalHoverMailbox.Entry?? = {
            lock.lock()
            defer { lock.unlock() }
            guard mailbox.ownerRevision == revision else { return nil }
            return .some(mailbox.acceptedOwner)
        }()
        guard let owner = outcome else { return }
        project(owner)
    }
}
