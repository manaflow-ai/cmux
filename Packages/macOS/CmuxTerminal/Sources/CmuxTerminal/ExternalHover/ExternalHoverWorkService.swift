internal import Foundation
public import CmuxTerminalCore

/// (B) ExternalHover — the actor that owns hover-candidate resolution,
/// caching, and every C read/set/clear call this mechanism makes.
///
/// Placed in `CmuxTerminal`, not `CmuxTerminalCore` (review Blocking 8):
/// it depends on `TerminalSurfaceRuntimeTeardownCoordinator` and
/// `RuntimeSurfaceLifetimeID`, both `CmuxTerminal`-only — `CmuxTerminal`
/// already depends on `CmuxTerminalCore`, so placing this service in Core
/// would be circular. `TerminalWrappedPathCellSpan`, the resolver, and the
/// mailbox/coordinator pure parts stay in Core; this actor is their sole
/// concrete consumer for (B).
///
/// One process-wide instance, injected the same way as
/// `TerminalSurfaceRuntimeTeardownCoordinator`. AppKit wiring (submitting
/// real requests from `GhosttyNSView`, and the concrete
/// `readPhysicalRows`/`callSetter`/`callClear` closures that actually call
/// `ghostty_surface_*`) is a later pass — this actor is complete and
/// independently testable with injected closures now.
public actor ExternalHoverWorkService {
    /// Reads the exact physical-row text for `[topRow, topRow+rowCount)`
    /// (viewport-relative, matching Ghostty's own contract), using the
    /// bounded C access `lease` borrows. `nil` on any failure.
    public typealias ReadPhysicalRows = @Sendable (
        _ lease: ExternalHoverSurfaceLease,
        _ topRow: UInt32,
        _ rowCount: UInt32
    ) -> String?

    /// Calls `ghostty_surface_set_external_link_hover` (or an injected
    /// double) using `lease`. `nil`/`.zero` on rejection.
    public typealias CallSetter = @Sendable (
        _ lease: ExternalHoverSurfaceLease,
        _ topRow: UInt32,
        _ rowCount: UInt32,
        _ text: String,
        _ ranges: [ExternalHoverCellRangeValue]
    ) -> HoverActivationTokenValue?

    /// Calls `ghostty_surface_clear_external_link_hover` (or an injected
    /// double) using `lease`.
    public typealias CallClear = @Sendable (
        _ lease: ExternalHoverSurfaceLease,
        _ token: HoverActivationTokenValue
    ) -> Void

    private let teardownCoordinator: TerminalSurfaceRuntimeTeardownCoordinator
    private let resolver: TerminalPathResolver
    private let readPhysicalRows: ReadPhysicalRows
    private let callSetter: CallSetter
    private let callClear: CallClear

    private var cachesByLifetime: [RuntimeSurfaceLifetimeID: ExternalHoverCandidateCache] = [:]
    /// The highest `requestGeneration` seen for each lifetime, updated
    /// unconditionally at the START of every `process(_:)` call — this is
    /// an ADDITIONAL defense against an out-of-order actor-queue arrival
    /// (review Blocking 5), never the sole acceptance boundary; the
    /// mirror-based `isCurrent` check below is.
    private var latestRequestGenerationByLifetime: [RuntimeSurfaceLifetimeID: UInt64] = [:]
    /// Lifetimes `invalidateSurface` has tombstoned. A request for a
    /// closed lifetime can never rebuild a cache entry, even if it
    /// otherwise looks current by generation — review Blocking 5's fix
    /// for the contradiction in the original design doc ("dropCache" vs.
    /// "the next process rebuilds it").
    private var closedLifetimes: Set<RuntimeSurfaceLifetimeID> = []

    /// Test-only accessor — no production caller needs to read the cache
    /// from outside the actor's own pipeline.
    func debugCache(for lifetimeID: RuntimeSurfaceLifetimeID) -> ExternalHoverCandidateCache? {
        cachesByLifetime[lifetimeID]
    }

    public init(
        teardownCoordinator: TerminalSurfaceRuntimeTeardownCoordinator,
        resolver: TerminalPathResolver = TerminalPathResolver(),
        readPhysicalRows: @escaping ReadPhysicalRows,
        callSetter: @escaping CallSetter,
        callClear: @escaping CallClear
    ) {
        self.teardownCoordinator = teardownCoordinator
        self.resolver = resolver
        self.readPhysicalRows = readPhysicalRows
        self.callSetter = callSetter
        self.callClear = callClear
    }

    /// The ONLY entry point `GhosttyNSView`'s AppKit event path calls
    /// (wired in a later pass). `nonisolated` and fire-and-forget — the
    /// main-thread hot path never `await`s this actor (review Blocking 1:
    /// generalized past its literal "no `DispatchQueue.main.sync`" wording
    /// to "no synchronous wait on this actor from the main event path" at
    /// all).
    ///
    /// Returns the underlying `Task` so deterministic tests can
    /// `await task.value` instead of a real-time poll; production callers
    /// (Pass 2's AppKit wiring) discard it — `@discardableResult` keeps
    /// that a plain statement, not an error.
    @discardableResult
    public nonisolated func submit(_ request: ExternalHoverWorkRequest) -> Task<Void, Never> {
        Task { await self.process(request) }
    }

    /// (B) wiring review Blocking 5 — acceptance boundary. `mirror`'s
    /// CURRENT snapshot, not any value captured earlier, must match
    /// `request.lifetimeID`/`requestGeneration` and report both
    /// eligible and visible. A stale/superseded request fails this and
    /// the caller must do nothing observable — no setter, no clear, no
    /// cache write, and (for `withdrawCurrentCandidate`) no mailbox
    /// mutation, since a stale request must never clear a newer owner.
    private func isCurrent(_ request: ExternalHoverWorkRequest) -> Bool {
        guard !closedLifetimes.contains(request.lifetimeID) else { return false }
        let snapshot = request.mirror.captureHoverCallbackSnapshot()
        return snapshot.lifetimeID == request.lifetimeID
            && snapshot.hoverEventID == request.requestGeneration
            && snapshot.eligible
            && snapshot.visible
    }

    private func process(_ request: ExternalHoverWorkRequest) async {
        latestRequestGenerationByLifetime[request.lifetimeID] = max(
            latestRequestGenerationByLifetime[request.lifetimeID] ?? 0,
            request.requestGeneration
        )
        // Checkpoint 1 (start).
        guard isCurrent(request) else { return }

        if let cached = cachesByLifetime[request.lifetimeID],
           cached.cwd == request.cwd,
           cached.contains(cell: request.cell) {
            await applySetter(using: cached, request: request)
            return
        }

        guard let resolvedCache = await resolveFully(request) else {
            // resolver nil, read failure, or out-of-bounds — the shared
            // withdrawal path handles "no candidate" uniformly; a genuine
            // read/bounds failure that never got as far as attempting a
            // resolve also just withdraws (there is nothing stale to
            // leave behind either way).
            await withdrawCurrentCandidate(request: request, reason: "noCandidate")
            return
        }

        // Checkpoint 2 (after fs resolve).
        guard isCurrent(request) else { return }
        await applySetter(using: resolvedCache, request: request)
    }

    /// Bounded 3-row read (clicked row + up to 1 adjacent each side,
    /// clamped to the viewport), resolved through the shared pure
    /// resolver (review Blocking 6's "reuse pure resolver/tokenizer only,
    /// never the click helper's whole-viewport read"). Returns a cache
    /// entry with `ranges` already materialized to absolute viewport
    /// coordinates, or `nil` on any failure (no candidate, no seed,
    /// unreadable text, or the read lease was refused).
    private func resolveFully(_ request: ExternalHoverWorkRequest) async -> ExternalHoverCandidateCache? {
        let clickedRow = request.cell.row
        let topRow = clickedRow > 0 ? clickedRow - 1 : clickedRow
        let rowCount = min(3, request.viewportRowCount - topRow)
        guard rowCount > 0 else { return nil }

        // Just-in-time read lease: acquired immediately before the C
        // call, released immediately after — never held across the fs
        // probe that follows (review Blocking 4).
        guard let readLease = await teardownCoordinator.acquireExternalHoverLease(
            lifetimeID: request.lifetimeID,
            surface: request.surface
        ) else { return nil }
        let text = readPhysicalRows(readLease, topRow, rowCount)
        await teardownCoordinator.releaseExternalHoverLease(readLease)
        guard let text else { return nil }

        guard let lines = text.splitPhysicalViewportRows(expectedRows: Int(rowCount)) else { return nil }
        let clickedIndex = Int(clickedRow - topRow)
        guard lines.indices.contains(clickedIndex) else { return nil }
        let clickedLine = lines[clickedIndex]

        guard let seed = resolver.wrappedPathSeed(in: clickedLine, column: request.cell.column, cwd: request.cwd) else {
            return nil
        }
        let previousLine = clickedIndex > 0 ? lines[clickedIndex - 1] : nil
        let nextLine = clickedIndex + 1 < lines.count ? lines[clickedIndex + 1] : nil
        guard let resolved = resolver.resolveWrappedCandidate(
            seed: seed, previousRow: previousLine, nextRow: nextLine, cwd: request.cwd
        ) else {
            return nil
        }

        let ranges = resolved.cellSpans.compactMap { span -> ExternalHoverCellRangeValue? in
            let absoluteRow = Int(clickedRow) + span.rowOffsetFromClicked
            guard absoluteRow >= 0, absoluteRow <= UInt16.max,
                  span.startColumn >= 0, span.endColumn <= Int(UInt16.max) + 1 else { return nil }
            return ExternalHoverCellRangeValue(
                row: UInt16(absoluteRow),
                startColumn: UInt16(span.startColumn),
                endColumn: UInt16(span.endColumn)
            )
        }
        guard ranges.count == resolved.cellSpans.count else { return nil }

        return ExternalHoverCandidateCache(
            lifetimeID: request.lifetimeID,
            cwd: request.cwd,
            topRow: topRow,
            rowCount: rowCount,
            physicalRowsText: text,
            ranges: ranges,
            path: resolved.path,
            activationToken: nil
        )
    }

    /// Calls the setter — inside the SAME mailbox critical section
    /// `ExternalHoverOwnerCoordinator.callSetterAndRecordPending` already
    /// establishes (never a separate C call followed by a second pass
    /// that only hands the coordinator an already-minted token — that
    /// would defeat the B0-6 lock-ordering fix this coordinator exists
    /// for). The setter lease itself is acquired just before this call and
    /// released immediately after, bounding it to the synchronous C call
    /// only.
    private func applySetter(using cache: ExternalHoverCandidateCache, request: ExternalHoverWorkRequest) async {
        // Checkpoint 3 (immediately before the setter call/cache commit).
        guard isCurrent(request) else { return }

        guard let setterLease = await teardownCoordinator.acquireExternalHoverLease(
            lifetimeID: request.lifetimeID,
            surface: request.surface
        ) else {
            cachesByLifetime.removeValue(forKey: request.lifetimeID)
            return
        }
        let minted = request.coordinator.callSetterAndRecordPending(
            event: request.requestGeneration,
            path: cache.path
        ) {
            self.callSetter(setterLease, cache.topRow, cache.rowCount, cache.physicalRowsText, cache.ranges)
        }
        await teardownCoordinator.releaseExternalHoverLease(setterLease)

        guard let minted else {
            // Setter rejected (stale token, ineligible, out of scope,
            // etc.) — the mailbox's pending/owner state for this
            // candidate is untouched (callSetterAndRecordPending never
            // wrote anything), but this cache entry must not survive: the
            // next eligible request must fully re-resolve rather than
            // re-present a candidate the setter has already refused once.
            cachesByLifetime.removeValue(forKey: request.lifetimeID)
            return
        }
        var committed = cache
        committed.activationToken = minted
        cachesByLifetime[request.lifetimeID] = committed
    }

    /// (B) wiring review Blocking 7 — the ONE shared withdrawal path.
    /// Resolver nil, setter rejection, Cmd release, selection/remote/
    /// ineligible, cwd change, visibility loss, and surface
    /// replacement/teardown all route here.
    ///
    /// NEVER calls `receiveTransition` — that is Ghostty's real
    /// `external_link_hover` action-callback entry point exclusively
    /// (Pass 2's `GHOSTTY_ACTION_EXTERNAL_LINK_HOVER` handler); synthesizing
    /// an `inactive` call here would misrepresent to the ack reducer that
    /// Ghostty itself sent one. `public` because Pass 2's AppKit wiring
    /// (a different module) calls this directly for every non-resolver
    /// invalidation trigger (Cmd release, selection, remote, cwd/scroll/
    /// resize, visibility loss, teardown) — `reason` is diagnostic only.
    public func withdrawCurrentCandidate(request: ExternalHoverWorkRequest, reason: String) async {
        // A stale request must not clear a newer owner.
        guard isCurrent(request) else { return }

        let removedToken = cachesByLifetime.removeValue(forKey: request.lifetimeID)?.activationToken
        let removedOwner = request.coordinator.withdrawUnconditionally()
        let tokenToClear = removedToken ?? removedOwner?.token
        guard let tokenToClear else { return }

        guard let lease = await teardownCoordinator.acquireExternalHoverLease(
            lifetimeID: request.lifetimeID,
            surface: request.surface
        ) else { return }
        callClear(lease, tokenToClear)
        await teardownCoordinator.releaseExternalHoverLease(lease)
    }

    /// A REAL `inactive` ack arrived (via the action-callback handler
    /// calling `receiveTransition`, wired in a later pass) for `token`.
    /// Non-blocking, cache-only: invalidates this lifetime's cache ONLY IF
    /// `token` still matches its `activationToken` — a core-side
    /// destructive invalidation the host didn't initiate must not be
    /// masked by a same-range cache hit reusing a token the render loop
    /// has already discarded (review Blocking 7's closing requirement).
    /// Never touches the mailbox — `receiveTransition` already did.
    /// Returns the underlying `Task` for deterministic tests; production
    /// callers discard it.
    @discardableResult
    public nonisolated func noteExternalInactive(
        lifetimeID: RuntimeSurfaceLifetimeID,
        token: HoverActivationTokenValue
    ) -> Task<Void, Never> {
        Task { await self.invalidateCacheIfTokenMatches(lifetimeID: lifetimeID, token: token) }
    }

    private func invalidateCacheIfTokenMatches(
        lifetimeID: RuntimeSurfaceLifetimeID,
        token: HoverActivationTokenValue
    ) {
        guard cachesByLifetime[lifetimeID]?.activationToken == token else { return }
        cachesByLifetime.removeValue(forKey: lifetimeID)
    }

    /// Surface replacement/teardown: closes `lifetimeID` (a monotonic
    /// tombstone, never reopened — a NEW lifetime for the same surfaceID
    /// gets its own fresh entry, never this one) and drops its cache and
    /// generation tracking. A request for this lifetime already in the
    /// actor's queue becomes a no-op via `isCurrent`'s
    /// `closedLifetimes` check, even if it would otherwise still look
    /// current by generation.
    @discardableResult
    public nonisolated func invalidateSurface(_ lifetimeID: RuntimeSurfaceLifetimeID) -> Task<Void, Never> {
        Task { await self.closeLifetime(lifetimeID) }
    }

    private func closeLifetime(_ lifetimeID: RuntimeSurfaceLifetimeID) {
        closedLifetimes.insert(lifetimeID)
        cachesByLifetime.removeValue(forKey: lifetimeID)
        latestRequestGenerationByLifetime.removeValue(forKey: lifetimeID)
    }
}
