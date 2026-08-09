import Testing
@testable import CmuxTerminalCore

/// A deterministic task queue standing in for `DispatchQueue.main.async`:
/// tasks are appended in enqueue order and only run when the test explicitly
/// drains them (in whatever order the test chooses), never via real-time
/// `sleep`. This is the scheduler seam the required (B) ExternalHover
/// coordinator tests use — see final-spec-B-external-hover.md's test
/// requirements (never real-time `sleep`).
final class DeterministicMainQueue: @unchecked Sendable {
    private(set) var tasks: [() -> Void] = []

    func schedule(_ task: @escaping () -> Void) {
        tasks.append(task)
    }

    /// Runs and removes exactly the next queued task.
    func runNext() {
        guard !tasks.isEmpty else { return }
        tasks.removeFirst()()
    }

    /// Runs every currently-queued task in FIFO order. Any task enqueued by
    /// a task that runs here is NOT included in this drain (call again to
    /// pick those up), matching one real turn of a run loop.
    func drainOneRound() {
        let batch = tasks
        tasks.removeAll()
        for task in batch { task() }
    }

    var count: Int { tasks.count }

    /// Removes and returns every currently-queued task without running any
    /// of them, so the test can run them itself in an arbitrary order.
    func takeAll() -> [() -> Void] {
        let batch = tasks
        tasks.removeAll()
        return batch
    }
}

@Suite("ExternalHoverOwnerCoordinator")
struct ExternalHoverOwnerCoordinatorTests {
    private static func token(_ seed: UInt64) -> HoverActivationTokenValue {
        HoverActivationTokenValue(bits: (seed, seed &+ 1, seed &+ 2, seed &+ 3))
    }

    private static func entry(_ seed: UInt64, event: UInt64 = 1, path: String = "/tmp/a") -> ExternalHoverMailbox.Entry {
        .init(event: event, token: token(seed), path: path)
    }

    private final class ProjectionRecorder: @unchecked Sendable {
        private(set) var applied: [ExternalHoverMailbox.Entry?] = []
        func record(_ entry: ExternalHoverMailbox.Entry?) {
            applied.append(entry)
        }
    }

    private func makeCoordinator(
        queue: DeterministicMainQueue,
        recorder: ProjectionRecorder
    ) -> ExternalHoverOwnerCoordinator {
        ExternalHoverOwnerCoordinator(
            scheduler: { queue.schedule($0) },
            project: { recorder.record($0) }
        )
    }

    /// Drives the full real-world sequence for one candidate: the setter
    /// call mints `seed`'s token as an OUT PARAMETER (never known in
    /// advance), then a separate token-only ack activates it — mirroring
    /// `ghostty_surface_set_external_link_hover`'s out-token followed by
    /// the `external_link_hover` action callback's `{token, active}`.
    @discardableResult
    private func acceptViaRealFlow(
        _ coordinator: ExternalHoverOwnerCoordinator,
        seed: UInt64,
        event: UInt64 = 1,
        path: String = "/tmp/a"
    ) -> HoverActivationTokenValue? {
        let minted = coordinator.callSetterAndRecordPending(
            event: event,
            path: path,
            setterCall: { Self.token(seed) }
        )
        guard let minted else { return nil }
        coordinator.receiveTransition(token: minted, active: true)
        return minted
    }

    // MARK: coordinator API fix — setter out-token order, token-only ack

    @Test("The setter mints the token as an out-parameter; pending is published with THAT token, not a caller-guessed one")
    func setterOutTokenBecomesPendingToken() {
        let queue = DeterministicMainQueue()
        let recorder = ProjectionRecorder()
        let coordinator = makeCoordinator(queue: queue, recorder: recorder)

        let minted = coordinator.callSetterAndRecordPending(
            event: 7,
            path: "/tmp/minted-path"
        ) {
            // The real Ghostty call: token is unknowable until this
            // returns.
            Self.token(42)
        }

        #expect(minted == Self.token(42))
        #expect(coordinator.currentMailbox.pending == .init(event: 7, token: Self.token(42), path: "/tmp/minted-path"))
        #expect(coordinator.currentMailbox.acceptedOwner == nil)
    }

    @Test("A setter failure (nil/.zero out-token) leaves any existing pending entry untouched")
    func setterFailureLeavesExistingPendingUntouched() {
        let queue = DeterministicMainQueue()
        let recorder = ProjectionRecorder()
        let coordinator = makeCoordinator(queue: queue, recorder: recorder)

        _ = coordinator.callSetterAndRecordPending(event: 1, path: "/tmp/a") { Self.token(1) }
        #expect(coordinator.currentMailbox.pending == Self.entry(1))

        let failedMint = coordinator.callSetterAndRecordPending(event: 2, path: "/tmp/b") { nil }
        #expect(failedMint == nil)
        #expect(coordinator.currentMailbox.pending == Self.entry(1))

        let zeroMint = coordinator.callSetterAndRecordPending(event: 2, path: "/tmp/b") { .zero }
        #expect(zeroMint == nil)
        #expect(coordinator.currentMailbox.pending == Self.entry(1))
    }

    // This is the deterministic race test the (B) wiring review required:
    // a token-only ack for a token that does NOT match the current pending
    // candidate must be rejected outright — the callback has no path/event
    // of its own to fall back on, so a mismatch can only mean the ack is
    // stale (answering a candidate `pending` has already moved past) or
    // foreign, and must never promote whatever unrelated entry happens to
    // be pending.
    @Test("A token-only ack for a token that doesn't match pending is rejected — never promotes an unrelated pending entry")
    func mismatchedTokenAckNeverPromotesUnrelatedPending() {
        let queue = DeterministicMainQueue()
        let recorder = ProjectionRecorder()
        let coordinator = makeCoordinator(queue: queue, recorder: recorder)

        _ = coordinator.callSetterAndRecordPending(event: 1, path: "/tmp/a") { Self.token(1) }
        #expect(coordinator.currentMailbox.pending == Self.entry(1))

        // An ack for a DIFFERENT token arrives (e.g. a stale ack for a
        // candidate that has since been superseded, or answering some
        // other surface's setter call entirely).
        let committed = coordinator.receiveTransition(token: Self.token(99), active: true)

        // (B) wiring review Blocking 5: an active-mismatch ack returns
        // false — the caller (the action handler) must relay this to
        // Ghostty's ack reducer so the core never treats it as published.
        #expect(committed == false)
        #expect(coordinator.currentMailbox.acceptedOwner == nil)
        #expect(coordinator.currentMailbox.pending == Self.entry(1))
        #expect(queue.count == 0)
    }

    @Test("A token-only ack matching pending promotes it to accepted owner with its full path/event")
    func matchingTokenAckPromotesPendingToOwner() {
        let queue = DeterministicMainQueue()
        let recorder = ProjectionRecorder()
        let coordinator = makeCoordinator(queue: queue, recorder: recorder)

        let minted = acceptViaRealFlow(coordinator, seed: 1, event: 5, path: "/tmp/real-path")

        #expect(minted != nil)
        #expect(coordinator.currentMailbox.acceptedOwner == .init(event: 5, token: Self.token(1), path: "/tmp/real-path"))
        #expect(coordinator.currentMailbox.pending == nil)
        queue.drainOneRound()
        #expect(recorder.applied == [.init(event: 5, token: Self.token(1), path: "/tmp/real-path")])
    }

    // (B) wiring review Blocking 5: receiveTransition's return value IS
    // the acceptance the action handler must relay verbatim to Ghostty's
    // ack reducer — this is the value that keeps host/core logical
    // ownership in sync.
    @Test("receiveTransition returns true only when the active ack's token matched pending")
    func receiveTransitionReturnValueMatchesActiveOutcome() {
        let queue = DeterministicMainQueue()
        let recorder = ProjectionRecorder()
        let coordinator = makeCoordinator(queue: queue, recorder: recorder)

        _ = coordinator.callSetterAndRecordPending(event: 1, path: "/tmp/a") { Self.token(1) }

        let matched = coordinator.receiveTransition(token: Self.token(1), active: true)
        #expect(matched == true)
    }

    @Test("receiveTransition always returns true for inactive, whether or not the token was owner")
    func receiveTransitionInactiveAlwaysReturnsTrue() {
        let queue = DeterministicMainQueue()
        let recorder = ProjectionRecorder()
        let coordinator = makeCoordinator(queue: queue, recorder: recorder)

        acceptViaRealFlow(coordinator, seed: 1)

        // Matching current owner.
        #expect(coordinator.receiveTransition(token: Self.token(1), active: false) == true)
        // A token that was never owner at all — idempotent success either way.
        #expect(coordinator.receiveTransition(token: Self.token(99), active: false) == true)
    }

    @Test("A false/error ack for a token that matches pending (but never activated) clears pending without becoming owner")
    func inactiveAckForPendingNeverActivatedClearsPending() {
        let queue = DeterministicMainQueue()
        let recorder = ProjectionRecorder()
        let coordinator = makeCoordinator(queue: queue, recorder: recorder)

        _ = coordinator.callSetterAndRecordPending(event: 1, path: "/tmp/a") { Self.token(1) }
        coordinator.receiveTransition(token: Self.token(1), active: false)

        #expect(coordinator.currentMailbox.pending == nil)
        #expect(coordinator.currentMailbox.acceptedOwner == nil)
    }

    // MARK: 1. setter->ack ordering: the setter call and the pending write
    // happen in the same lock section; only a later, separate
    // `receiveTransition(active: true)` call makes a matching owner appear.

    @Test("The setter call never itself produces acceptance; only a later, separate token-only ack does")
    func setterCallNeverProducesAcceptanceItself() {
        let queue = DeterministicMainQueue()
        let recorder = ProjectionRecorder()
        let coordinator = makeCoordinator(queue: queue, recorder: recorder)

        var setterRan = false
        let minted = coordinator.callSetterAndRecordPending(event: 1, path: "/tmp/a") {
            // The real Ghostty setter call is fire-and-forget from this
            // closure's point of view: it takes ITS OWN renderer mutex
            // internally and returns, without synchronously calling back
            // into the mailbox — so this closure must never itself take
            // the mailbox lock (that would self-deadlock, since
            // `callSetterAndRecordPending` already holds it here). It only
            // observes that it ran and mints a token.
            setterRan = true
            return Self.token(1)
        }

        #expect(setterRan)
        #expect(minted == Self.token(1))
        // Immediately after the setter call returns, nothing has been
        // accepted yet — `callSetterAndRecordPending` only ever publishes
        // `pending`, never `acceptedOwner`. Acceptance is exclusively
        // `receiveTransition(active: true)`'s job, called separately once
        // Ghostty's ack actually arrives.
        #expect(coordinator.currentMailbox.acceptedOwner == nil)
        #expect(coordinator.currentMailbox.pending == Self.entry(1))
        #expect(queue.count == 0)

        // Only now does the "ack" arrive (as a separate call, after the
        // setter returned) and acceptance becomes visible.
        coordinator.receiveTransition(token: Self.token(1), active: true)
        #expect(coordinator.currentMailbox.acceptedOwner == Self.entry(1))
    }

    // MARK: 2. A pending-only mutation never invalidates an accepted
    // owner's queued projection task; only a NEW owner mutation does.

    @Test("A pending-only change leaves an accepted owner's queued projection valid")
    func pendingOnlyChangeLeavesOwnerProjectionValid() {
        let queue = DeterministicMainQueue()
        let recorder = ProjectionRecorder()
        let coordinator = makeCoordinator(queue: queue, recorder: recorder)

        acceptViaRealFlow(coordinator, seed: 1)
        #expect(queue.count == 1)

        _ = coordinator.callSetterAndRecordPending(event: 1, path: "/tmp/b") { Self.token(2) }

        queue.drainOneRound()
        #expect(recorder.applied == [Self.entry(1)])
    }

    @Test("A new event clearing the accepted owner makes the older queued projection a no-op")
    func newOwnerMutationInvalidatesOlderQueuedProjection() {
        let queue = DeterministicMainQueue()
        let recorder = ProjectionRecorder()
        let coordinator = makeCoordinator(queue: queue, recorder: recorder)

        acceptViaRealFlow(coordinator, seed: 1)
        // Do NOT drain yet: a second, real owner mutation (a new event
        // clearing this owner) arrives before the first projection runs.
        coordinator.receiveTransition(token: Self.token(1), active: false)

        queue.drainOneRound()

        // Both queued tasks run; the first (stale) one must be a no-op
        // because its captured revision no longer matches, and only the
        // second (current) projection actually applies.
        #expect(recorder.applied == [nil])
    }

    // MARK: 3. Owner-projection tasks converge to `none` regardless of run
    // order.

    @Test(
        "T->U->none owner-projection tasks converge to none regardless of run order",
        arguments: [[0, 1, 2], [2, 1, 0], [1, 0, 2], [0, 2, 1]]
    )
    func projectionTasksConvergeRegardlessOfOrder(runOrder: [Int]) {
        let queue = DeterministicMainQueue()
        let recorder = ProjectionRecorder()
        let coordinator = makeCoordinator(queue: queue, recorder: recorder)

        acceptViaRealFlow(coordinator, seed: 1) // T
        acceptViaRealFlow(coordinator, seed: 2) // U
        coordinator.receiveTransition(token: Self.token(2), active: false) // -> none

        #expect(queue.count == 3)
        let tasks = queue.takeAll()
        for index in runOrder {
            tasks[index]()
        }

        // Every task independently re-checks the *current* revision, so no
        // matter which order they run in, only the projection matching the
        // final revision (none) ever actually applies to `recorder`.
        #expect(coordinator.currentMailbox.acceptedOwner == nil)
        #expect(recorder.applied.last == .some(nil))
        #expect(recorder.applied.allSatisfy { $0 == nil })
    }

    // MARK: 4. A delayed inactive(T) after the owner has moved to nil/U
    // must not clear U and must return true.

    @Test("A delayed inactive ack after owner moved to nil does not resurrect T")
    func delayedInactiveAfterOwnerClearedDoesNotResurrect() {
        let queue = DeterministicMainQueue()
        let recorder = ProjectionRecorder()
        let coordinator = makeCoordinator(queue: queue, recorder: recorder)

        acceptViaRealFlow(coordinator, seed: 1)
        coordinator.receiveTransition(token: Self.token(1), active: false)
        #expect(coordinator.currentMailbox.acceptedOwner == nil)

        // A delayed retry of the same inactive ack.
        coordinator.receiveTransition(token: Self.token(1), active: false)
        #expect(coordinator.currentMailbox.acceptedOwner == nil)
    }

    @Test("A delayed inactive ack after owner moved to U does not clear U")
    func delayedInactiveAfterOwnerMovedToUDoesNotClearU() {
        let queue = DeterministicMainQueue()
        let recorder = ProjectionRecorder()
        let coordinator = makeCoordinator(queue: queue, recorder: recorder)

        acceptViaRealFlow(coordinator, seed: 1) // T
        acceptViaRealFlow(coordinator, seed: 2) // U

        // Stale inactive(T) arrives after U is already owner.
        coordinator.receiveTransition(token: Self.token(1), active: false)
        #expect(coordinator.currentMailbox.acceptedOwner == Self.entry(2))
    }

    // MARK: 5. Accepted T's path still projects correctly after a later
    // pending-U replacement.

    @Test("Accepted owner's path still projects correctly after a later pending replacement")
    func acceptedOwnerPathProjectsAfterLaterPendingReplacement() {
        let queue = DeterministicMainQueue()
        let recorder = ProjectionRecorder()
        let coordinator = makeCoordinator(queue: queue, recorder: recorder)

        acceptViaRealFlow(coordinator, seed: 1, path: "/tmp/first")
        _ = coordinator.callSetterAndRecordPending(event: 1, path: "/tmp/second") { Self.token(2) }

        queue.drainOneRound()
        #expect(recorder.applied == [Self.entry(1, path: "/tmp/first")])
    }

    // MARK: 6. A queued task after surface teardown is a no-op.

    @Test("A projection task queued before teardown is a no-op once it runs")
    func projectionQueuedBeforeTeardownIsNoOp() {
        let queue = DeterministicMainQueue()
        let recorder = ProjectionRecorder()
        let coordinator = makeCoordinator(queue: queue, recorder: recorder)

        acceptViaRealFlow(coordinator, seed: 1)
        // teardown immediately after, before the first task drains.
        coordinator.teardown()

        queue.drainOneRound()
        #expect(recorder.applied == [nil])
        #expect(coordinator.currentMailbox.acceptedOwner == nil)
        #expect(coordinator.currentMailbox.pending == nil)
    }

    @Test("A projection task queued and run, THEN teardown, still tombstones correctly")
    func teardownAfterProjectionAlreadyRan() {
        let queue = DeterministicMainQueue()
        let recorder = ProjectionRecorder()
        let coordinator = makeCoordinator(queue: queue, recorder: recorder)

        acceptViaRealFlow(coordinator, seed: 1)
        queue.drainOneRound()
        #expect(recorder.applied == [Self.entry(1)])

        coordinator.teardown()
        queue.drainOneRound()
        #expect(recorder.applied == [Self.entry(1), nil])
    }

    // MARK: withdrawUnconditionally (B) wiring review Blocking 7

    @Test("withdrawUnconditionally clears both pending and the accepted owner in one call, returning the removed owner")
    func withdrawUnconditionallyClearsBothPendingAndOwner() {
        let queue = DeterministicMainQueue()
        let recorder = ProjectionRecorder()
        let coordinator = makeCoordinator(queue: queue, recorder: recorder)

        acceptViaRealFlow(coordinator, seed: 1, path: "/tmp/accepted")
        _ = coordinator.callSetterAndRecordPending(event: 1, path: "/tmp/pending") { Self.token(2) }
        #expect(coordinator.currentMailbox.pending != nil)
        #expect(coordinator.currentMailbox.acceptedOwner != nil)

        let removed = coordinator.withdrawUnconditionally()

        #expect(removed == Self.entry(1, path: "/tmp/accepted"))
        #expect(coordinator.currentMailbox.pending == nil)
        #expect(coordinator.currentMailbox.acceptedOwner == nil)
        queue.drainOneRound()
        #expect(recorder.applied.last == .some(nil))
    }

    @Test("withdrawUnconditionally with no accepted owner returns nil and schedules no projection")
    func withdrawUnconditionallyWithNoOwnerIsANoOp() {
        let queue = DeterministicMainQueue()
        let recorder = ProjectionRecorder()
        let coordinator = makeCoordinator(queue: queue, recorder: recorder)

        _ = coordinator.callSetterAndRecordPending(event: 1, path: "/tmp/pending") { Self.token(1) }
        let removed = coordinator.withdrawUnconditionally()

        #expect(removed == nil)
        #expect(coordinator.currentMailbox.pending == nil)
        #expect(queue.count == 0)
    }
}
