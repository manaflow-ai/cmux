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
    /// (C) ExternalHover diagnostics — retains (`true`) or releases
    /// (`false`) the surface's `externalHoverDiagnostics` render demand
    /// (design v4 §3.4's "render 後" trigger). Called OUTSIDE the mailbox
    /// lock, same discipline as `scheduler`/`project`. May be invoked from
    /// any isolation — `callSetterAndRecordPending` runs on
    /// `ExternalHoverWorkService`'s actor, not necessarily the main actor
    /// — but does NOT hop to main itself: review round2 B1 made the
    /// production implementation (`RenderDemandActivationTracker.setActive`,
    /// wired in via that type's `makeExternalHoverOwnerCoordinator`
    /// factory — review round3 B2) a synchronous, lock-protected retain/
    /// release instead, since the renderer thread needs to observe the
    /// retained demand by the time THIS call returns, not on some later
    /// main-queue turn. The regression test that exercises this specific
    /// wiring goes through that same factory rather than a hand-rolled
    /// recorder closure, so production and test share one composition
    /// path for it.
    public typealias ManageDiagnosticsRenderDemand = (Bool) -> Void
    /// (C) ExternalHover diagnostics — review B1: an injectable seam for
    /// design v4 §7 guard 4's "gate OFF ⇒ no allocation/ring/demand work",
    /// rather than hardcoding `ExternalHoverDiagnosticsGate.isEnabled`
    /// directly at each call site. Production composition never overrides
    /// this (the default IS the real gate); tests inject a controllable
    /// closure, since the real gate is a process-wide memoized `static
    /// let` that a single `swift test` run can never flip both ways.
    public typealias DiagnosticsEnabled = @Sendable () -> Bool

    /// (C) ExternalHover diagnostics — design v4 §5's `transition` stage,
    /// design v4 §7 guard 1: ONE structured outcome, computed from the
    /// SAME checks `receiveTransition` already makes for its production
    /// accept/reject decision, reused verbatim for this diagnostic value
    /// — never a second/duplicated match judgment. `event` is whichever
    /// entry (pending, or accepted owner) the token actually matched;
    /// `nil` if it matched neither (a fully stale/foreign token).
    public struct TransitionVerdict: Sendable, Equatable {
        public let active: Bool
        /// Whether `token` identified ANYTHING this coordinator is
        /// currently tracking (pending OR the accepted owner) — broader
        /// than `pendingMatched` alone.
        public let identityMatched: Bool
        /// Whether `token` specifically matched the CURRENT `pending`
        /// entry (checked independently in both the active and inactive
        /// paths, matching the production code's own two separate
        /// pending-token comparisons).
        public let pendingMatched: Bool
        /// Whether this call actually mutated the mailbox's owner state
        /// (accept: promoted pending to owner; inactive: cleared the
        /// owner) — `false` for an inactive ack that only matched
        /// `pending` (or matched nothing at all).
        public let committed: Bool
        public let event: UInt64?
    }
    /// Called AFTER every mailbox lock this call touches has released —
    /// same discipline as `scheduler`/`project`/
    /// `manageDiagnosticsRenderDemand` (design v4 §6.3: "診断のために
    /// callback/dispatchをlock内へ追加してはならない").
    public typealias LogTransition = (TransitionVerdict) -> Void

    private let lock = NSLock()
    private var mailbox = ExternalHoverMailbox()

    private let scheduler: Scheduler
    private let project: Project
    private let manageDiagnosticsRenderDemand: ManageDiagnosticsRenderDemand
    private let logTransition: LogTransition
    private let diagnosticsEnabled: DiagnosticsEnabled

    /// (C) diagnostics — review B2: which events still have a render
    /// demand armed on their behalf, so `manageDiagnosticsRenderDemand`
    /// is only released once EVERY event that armed it has reached its own
    /// terminal outcome — never on "any entry was drained", which could
    /// release a newer overlapping activation's demand using an older
    /// activation's unrelated ring entry. Guarded by its own lock, never
    /// the mailbox `lock` — arming must happen BEFORE
    /// `callSetterAndRecordPending` takes the mailbox lock (so it precedes
    /// Ghostty's synchronous in-setter `queueRender()`), and release is
    /// driven by ring-drain results that must never run inside that lock.
    private let diagnosticsLock = NSLock()
    private var pendingDiagnosticsRenderEvents: Set<UInt64> = []

    /// - Parameters:
    ///   - scheduler: Enqueues a main-thread task. Production callers pass
    ///     `{ DispatchQueue.main.async(execute: $0) }`; tests pass a
    ///     deterministic seam (e.g. appending to an array of pending tasks
    ///     the test drains in whatever order it wants to exercise), never a
    ///     real-time `sleep`.
    ///   - project: Applies an accepted-owner snapshot (or `nil`) to the
    ///     view. Always called from a task the `scheduler` ran, never
    ///     synchronously from any of this type's own methods.
    ///   - manageDiagnosticsRenderDemand: See the typealias doc. Defaults
    ///     to a no-op so existing call sites/tests that don't care about
    ///     (C) diagnostics are unaffected.
    ///   - logTransition: See the typealias doc. Defaults to a no-op.
    ///   - diagnosticsEnabled: See the typealias doc. Defaults to the real
    ///     host gate.
    public init(
        scheduler: @escaping Scheduler,
        project: @escaping Project,
        manageDiagnosticsRenderDemand: @escaping ManageDiagnosticsRenderDemand = { _ in },
        logTransition: @escaping LogTransition = { _ in },
        diagnosticsEnabled: @escaping DiagnosticsEnabled = { ExternalHoverDiagnosticsGate.isEnabled }
    ) {
        self.scheduler = scheduler
        self.project = project
        self.manageDiagnosticsRenderDemand = manageDiagnosticsRenderDemand
        self.logTransition = logTransition
        self.diagnosticsEnabled = diagnosticsEnabled
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
        // (C) diagnostics — review B2: armed BEFORE `setterCall` runs (and
        // therefore before Ghostty's own synchronous in-setter
        // `queueRender()` can fire), not after this method returns. Arming
        // speculatively for every attempt, successful or not, is what
        // closes the race — by the time `setterCall` can possibly trigger
        // a render, the demand is already retained. Outside the mailbox
        // lock, matching `scheduler`/`project`'s discipline (`setterCall`
        // itself still runs inside the lock below, unchanged from before).
        let diagnosticsOn = diagnosticsEnabled()
        if diagnosticsOn {
            armDiagnosticsDemand(for: event)
        }
        let token: HoverActivationTokenValue? = {
            lock.lock()
            defer { lock.unlock() }
            guard let token = setterCall(), token != .zero else { return nil }
            mailbox.setPending(.init(event: event, token: token, path: path))
            return token
        }()
        if diagnosticsOn {
            if token == nil {
                // Rejected: this event's terminal outcome is already known
                // synchronously (design v4's `setter reject` terminal
                // condition) — no render will ever come for it, so there is
                // nothing left for the render trigger to wait for. The
                // prior core activation (if any) is untouched by a
                // rejection, so it must NOT be superseded here.
                releaseDiagnosticsDemand(for: event)
            } else {
                // (C) diagnostics — review round2 B2: Ghostty holds exactly
                // ONE external_hover override per surface, and this
                // successful setter call just replaced it. Any OTHER event
                // still armed in `pendingDiagnosticsRenderEvents` (an
                // earlier successful setter call whose own terminal ring
                // entry never arrived before this one superseded it, or an
                // earlier one still pending its ack) represents an
                // activation Ghostty has now discarded — its terminal ring
                // entry will never be generated, so it must be treated as
                // superseded-terminal now rather than left armed forever.
                supersedePriorDiagnosticsDemand(keeping: event)
            }
        }
        return token
    }

    /// (C) diagnostics — review B2/B3: called once a drained ring entry
    /// (or an equivalent synchronously-known outcome) has been identified
    /// as `event`'s terminal entry — a `firstForActivation` render
    /// verdict, or a post-accept `renderQueueFailed`. Idempotent: releasing
    /// an event that was never armed (already released, or never armed to
    /// begin with) is a harmless no-op. Never touches the mailbox lock.
    public func noteDiagnosticsTerminalEntry(event: UInt64) {
        releaseDiagnosticsDemand(for: event)
    }

    private func armDiagnosticsDemand(for event: UInt64) {
        let shouldRetain: Bool = {
            diagnosticsLock.lock()
            defer { diagnosticsLock.unlock() }
            let wasEmpty = pendingDiagnosticsRenderEvents.isEmpty
            pendingDiagnosticsRenderEvents.insert(event)
            return wasEmpty
        }()
        if shouldRetain {
            manageDiagnosticsRenderDemand(true)
        }
    }

    private func releaseDiagnosticsDemand(for event: UInt64) {
        let shouldRelease: Bool = {
            diagnosticsLock.lock()
            defer { diagnosticsLock.unlock() }
            guard pendingDiagnosticsRenderEvents.remove(event) != nil else { return false }
            return pendingDiagnosticsRenderEvents.isEmpty
        }()
        if shouldRelease {
            manageDiagnosticsRenderDemand(false)
        }
    }

    /// (C) diagnostics — review round2 B2: prunes every armed event OTHER
    /// than `event` (the one whose setter call just succeeded) from
    /// `pendingDiagnosticsRenderEvents`. If that leaves no event armed, it
    /// releases the shared diagnostics render demand; the lock-protected
    /// result is authoritative if the normal arm-before-setter assumption
    /// changes.
    private func supersedePriorDiagnosticsDemand(keeping event: UInt64) {
        let shouldRelease: Bool = {
            diagnosticsLock.lock()
            defer { diagnosticsLock.unlock() }
            pendingDiagnosticsRenderEvents = pendingDiagnosticsRenderEvents.filter { $0 == event }
            return pendingDiagnosticsRenderEvents.isEmpty
        }()
        if shouldRelease {
            manageDiagnosticsRenderDemand(false)
        }
    }

    private func releaseAllDiagnosticsDemand() {
        let shouldRelease: Bool = {
            diagnosticsLock.lock()
            defer { diagnosticsLock.unlock() }
            guard !pendingDiagnosticsRenderEvents.isEmpty else { return false }
            pendingDiagnosticsRenderEvents.removeAll()
            return true
        }()
        if shouldRelease {
            manageDiagnosticsRenderDemand(false)
        }
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
            let outcome = acceptPendingIfTokenMatches(token)
            if let revision = outcome.revision {
                enqueueProjection(atRevision: revision)
            }
            logTransition(TransitionVerdict(
                active: true,
                identityMatched: outcome.pendingMatched,
                pendingMatched: outcome.pendingMatched,
                committed: outcome.pendingMatched,
                event: outcome.event
            ))
            return outcome.pendingMatched
        }
        let pendingOutcome = clearPendingIfTokenMatches(token)
        let inactiveOutcome = inactive(token: token)
        logTransition(TransitionVerdict(
            active: false,
            identityMatched: pendingOutcome.matched || inactiveOutcome.wasOwner,
            pendingMatched: pendingOutcome.matched,
            committed: inactiveOutcome.wasOwner,
            event: inactiveOutcome.event ?? pendingOutcome.event
        ))
        return true
    }

    private struct AcceptOutcome {
        let pendingMatched: Bool
        let event: UInt64?
        let revision: UInt64?
    }

    private func acceptPendingIfTokenMatches(_ token: HoverActivationTokenValue) -> AcceptOutcome {
        lock.lock()
        defer { lock.unlock() }
        if let pendingEntry = mailbox.pending, pendingEntry.token == token {
            mailbox.acceptActive(pendingEntry)
            return AcceptOutcome(pendingMatched: true, event: pendingEntry.event, revision: mailbox.ownerRevision)
        }
        return AcceptOutcome(pendingMatched: false, event: nil, revision: nil)
    }

    private struct ClearPendingOutcome {
        let matched: Bool
        let event: UInt64?
    }

    private func clearPendingIfTokenMatches(_ token: HoverActivationTokenValue) -> ClearPendingOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard let pendingEntry = mailbox.pending, pendingEntry.token == token else {
            return ClearPendingOutcome(matched: false, event: nil)
        }
        mailbox.clearPending()
        return ClearPendingOutcome(matched: true, event: pendingEntry.event)
    }

    private struct InactiveOutcome {
        let wasOwner: Bool
        let event: UInt64?
    }

    /// Ghostty's ack arrived with `active == false` (or an error/timeout)
    /// for `token`. Idempotent per final-spec: if `token` is not the
    /// current owner (already replaced by a newer accept, or already
    /// cleared), the postcondition already holds and this returns
    /// `wasOwner == false` (still an idempotent no-op — the caller's
    /// production return value stays unconditionally `true` regardless)
    /// without touching whatever newer owner is installed and without
    /// scheduling a projection (nothing observable changed) — this is what
    /// lets a stale core-side inactive retry terminate instead of racing a
    /// newer accept. Only clears and schedules a projection when `token`
    /// really was the current owner.
    private func inactive(token: HoverActivationTokenValue) -> InactiveOutcome {
        var didClear = false
        var matchedEvent: UInt64?
        let revision: UInt64 = {
            lock.lock()
            defer { lock.unlock() }
            let ownedEntry = mailbox.acceptedOwner
            let wasOwner = ownedEntry?.token == token
            _ = mailbox.inactive(token: token)
            didClear = wasOwner
            matchedEvent = wasOwner ? ownedEntry?.event : nil
            return mailbox.ownerRevision
        }()
        if didClear {
            enqueueProjection(atRevision: revision)
        }
        return InactiveOutcome(wasOwner: didClear, event: matchedEvent)
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
        var removedPending: ExternalHoverMailbox.Entry?
        var removed: ExternalHoverMailbox.Entry?
        let revision: UInt64 = {
            lock.lock()
            defer { lock.unlock() }
            removedPending = mailbox.clearPending()
            removed = mailbox.clearOwnerUnconditionally()
            return mailbox.ownerRevision
        }()
        // (C) diagnostics — review B2: a withdrawn candidate, whether it
        // was only `pending` (setter accepted, no ack yet) or already the
        // accepted owner, will never produce a future terminal ring entry
        // — release whatever demand its own event armed rather than
        // leaving it retained forever. Outside the mailbox lock, matching
        // every other diagnostics call this coordinator makes.
        if diagnosticsEnabled() {
            if let event = removedPending?.event {
                releaseDiagnosticsDemand(for: event)
            }
            if let event = removed?.event, event != removedPending?.event {
                releaseDiagnosticsDemand(for: event)
            }
        }
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
        // (C) diagnostics — the surface is going away; no future render
        // trigger will ever fire for it, so any still-armed demand must be
        // released now rather than leaking.
        if diagnosticsEnabled() {
            releaseAllDiagnosticsDemand()
        }
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
