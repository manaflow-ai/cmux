public import Foundation
public import GhosttyKit
public import CmuxTerminalCore
internal import Dispatch
#if DEBUG
internal import CMUXDebugLog
#endif

/// Coordinates native `ghostty_surface_free` calls off the close/deinit paths.
///
/// Close/deinit frees run on a bounded set of utility slots so one stuck native
/// join cannot strand later closes. Each admitted hibernation owns a separate,
/// independently startable utility slot. Deadline observers report, but never
/// block on, stuck frees. The app constructs exactly one instance and injects it
/// through
/// ``TerminalSurfaceRuntimeDependencies``.
public actor TerminalSurfaceRuntimeTeardownCoordinator {
    /// Maximum number of close/deinit native frees that can run concurrently.
    public static let maximumConcurrentCloseTeardownCount = 2

    /// Largest batch that can own independently startable native-free slots.
    public static let maximumIsolatedHibernationTeardownCount = 2

    /// (C) diagnostics — review round3 B4: the raw C drain + POD decode
    /// `defaultDrainExternalHoverDiagnostics` performs, pulled out into an
    /// injectable seam so a test can supply canned entries and observe
    /// them reach the REAL default formatter/log sink, instead of either
    /// bypassing `defaultDrainExternalHoverDiagnostics` entirely (an
    /// injected `drainDiagnostics` on `enqueueRuntimeTeardown` itself,
    /// which the review rejects as not exercising the production path) or
    /// needing a real live Ghostty surface. Production composition never
    /// overrides this — the default IS the real
    /// `ghostty_surface_drain_external_hover_diagnostics` call + decode.
    public typealias DrainExternalHoverRing = @Sendable (
        _ surface: ghostty_surface_t
    ) -> (entries: [ExternalHoverDiagEntryValue], droppedCountCumulative: UInt64)

    /// (C) diagnostics — review round3 B4/B1: matches
    /// `ExternalHoverWorkService.DiagnosticsEnabled`'s own rationale —
    /// `defaultDrainExternalHoverDiagnostics` reads the injected gate
    /// rather than the static `ExternalHoverDiagnosticsGate.isEnabled`
    /// directly, so a test can flip it independently of the real
    /// process-wide env var.
    public typealias DiagnosticsEnabled = @Sendable () -> Bool

    private let timeout: Duration = .seconds(5)
#if DEBUG
    // Readable at internal scope in DEBUG so the debug-only extension in
    // TerminalSurfaceRuntimeTeardownCoordinator+Debug.swift can report the
    // pending count; private in release builds.
    var pendingReasonsById: [UUID: String] = [:]
#else
    private var pendingReasonsById: [UUID: String] = [:]
#endif
    private var queuedCloseRequests: [TerminalSurfaceRuntimeTeardownRequest] = []
    private var availableCloseExecutionSlots: Set<Int>
    private let closeTeardownQueues: [DispatchQueue]
    private let isolatedHibernationQueues: [DispatchQueue]
    private nonisolated let isolatedHibernationAdmission =
        TerminalSurfaceRuntimeTeardownAdmission()
    private nonisolated let externalHoverInvalidationTasks = ExternalHoverInvalidationTaskRegistry()

    // cmux fork: (B) ExternalHover — native-surface lease. See
    // `acquireExternalHoverLease`/`releaseExternalHoverLease` below.

    /// Outstanding lease IDs per runtime lifetime. A lifetime with a
    /// nonempty set here must not be freed yet — `enqueue(_:)` defers the
    /// free until the set empties.
    private var outstandingHoverLeaseIDs: [RuntimeSurfaceLifetimeID: Set<UUID>] = [:]
    /// The highest `runtimeSurfaceGeneration` ever torn down, per
    /// surfaceID. A monotonic watermark, never removed: `runtimeSurfaceGeneration`
    /// is per-surfaceID monotonic (bumped only on install/removal — see
    /// `TerminalSurface.surface`'s setter), so a generation at or below
    /// this watermark can never legitimately be acquired again — it names
    /// a lifetime that has already ended. This is what lets a lifetime be
    /// safely retired without needing a *permanent* per-lifetime tombstone
    /// entry (which would leak forever across repeated hibernate/resume
    /// cycles) while still refusing a lease to a delayed, stale acquire.
    private var retiredRuntimeGenerationWatermark: [UUID: UInt64] = [:]
    /// A teardown request that arrived while a hover lease was still
    /// outstanding for its lifetime, held in full (not just the request)
    /// so the deferred admission preserves the original execution lane and
    /// hibernation reservation — see `DeferredRuntimeTeardown`.
    private var deferredHoverTeardowns: [RuntimeSurfaceLifetimeID: DeferredRuntimeTeardown] = [:]

    /// (C) diagnostics — review B5: shared with `ExternalHoverWorkService`
    /// (which reads this same instance off its own `teardownCoordinator`
    /// dependency at construction — see that type's `init`), so the
    /// setter/render-trigger/withdrawal drains and this coordinator's own
    /// final teardown drain linearize against ONE per-lifetime
    /// dropped-count baseline instead of each keeping (or, before this
    /// fix, not even keeping) their own. Plain `let`, not actor-isolated
    /// state — the tracker is its own thread-safe type, readable from the
    /// `nonisolated` teardown drain path without an `await`.
    public nonisolated let droppedCountTracker = ExternalHoverDroppedCountTracker()

    /// (C) diagnostics — review round2 B5: shared with
    /// `ExternalHoverWorkService` the same way `droppedCountTracker` is —
    /// see `ExternalHoverSurfaceSerialRegistry`'s own doc.
    public nonisolated let surfaceSerialRegistry = ExternalHoverSurfaceSerialRegistry()

    /// (C) diagnostics — review round3 B4. `nonisolated`, matching
    /// `defaultDrainExternalHoverDiagnostics`'s own isolation — see
    /// `DrainExternalHoverRing`'s doc. The default diagnostic flow reads this
    /// injected source when the diagnostics gate is enabled.
    private nonisolated let drainExternalHoverRing: DrainExternalHoverRing

    /// (C) diagnostics — review round3 B4/B1. The default diagnostic flow
    /// reads this injected gate before draining the ring, so tests and
    /// production use the same gate contract.
    private nonisolated let diagnosticsEnabled: DiagnosticsEnabled

    /// Creates the process's teardown coordinator.
    public init(
        drainExternalHoverRing: @escaping DrainExternalHoverRing = TerminalSurfaceRuntimeTeardownCoordinator.defaultDrainExternalHoverRing,
        diagnosticsEnabled: @escaping DiagnosticsEnabled = { ExternalHoverDiagnosticsGate.isEnabled }
    ) {
        self.drainExternalHoverRing = drainExternalHoverRing
        self.diagnosticsEnabled = diagnosticsEnabled
        availableCloseExecutionSlots = Set(
            0..<Self.maximumConcurrentCloseTeardownCount
        )
        closeTeardownQueues = (
            0..<Self.maximumConcurrentCloseTeardownCount
        ).map { executionSlot in
            DispatchQueue(
                label: "com.cmux.terminal-surface-close-teardown.\(executionSlot)",
                qos: .utility
            )
        }
        isolatedHibernationQueues = (
            0..<Self.maximumIsolatedHibernationTeardownCount
        ).map { executionSlot in
            DispatchQueue(
                label: "com.cmux.terminal-surface-hibernation-teardown.\(executionSlot)",
                qos: .utility
            )
        }
    }

    /// The REAL drain: calls `ghostty_surface_drain_external_hover_diagnostics`
    /// and decodes each raw POD entry into `ExternalHoverDiagEntryValue` —
    /// exactly what `defaultDrainExternalHoverDiagnostics` used to do
    /// inline. `nonisolated static` so it can serve as a default
    /// parameter expression.
    public nonisolated static func defaultDrainExternalHoverRing(
        _ surface: ghostty_surface_t
    ) -> (entries: [ExternalHoverDiagEntryValue], droppedCountCumulative: UInt64) {
        var buffer = [ghostty_external_hover_diag_entry_s](
            repeating: ghostty_external_hover_diag_entry_s(), count: 64
        )
        var droppedCumulative: UInt64 = 0
        let count: Int = buffer.withUnsafeMutableBufferPointer { buf in
            Int(ghostty_surface_drain_external_hover_diagnostics(
                surface, buf.baseAddress, buf.count, &droppedCumulative
            ))
        }
        let entries = (0..<count).map { index -> ExternalHoverDiagEntryValue in
            let raw = buffer[index]
            return ExternalHoverDiagEntryValue(
                event: raw.event, source: raw.source, reason: raw.reason,
                verdict: raw.verdict, flags: raw.flags, seq: raw.seq
            )
        }
        return (entries: entries, droppedCountCumulative: droppedCumulative)
    }

    @MainActor
    func reserveIsolatedHibernationTeardown()
        -> TerminalSurfaceRuntimeTeardownReservation? {
        isolatedHibernationAdmission.reserve()
    }

    @MainActor
    func cancelIsolatedHibernationTeardown(
        _ reservation: TerminalSurfaceRuntimeTeardownReservation
    ) {
        isolatedHibernationAdmission.release(reservation)
    }

    /// Borrows `surface` for one bounded, off-main external-hover C access.
    /// Fails closed (`nil`) once `lifetimeID`'s generation is at or below
    /// this surfaceID's retired watermark — i.e. once this lifetime's
    /// teardown has already been requested or completed. The caller must
    /// re-acquire (this does not hold across suspension): read scope +
    /// setter should each take their own short-lived lease, never one held
    /// across an `fs probe or other suspension (review Blocking 4).
    func acquireExternalHoverLease(
        lifetimeID: RuntimeSurfaceLifetimeID,
        surface: ghostty_surface_t
    ) -> ExternalHoverSurfaceLease? {
        if let watermark = retiredRuntimeGenerationWatermark[lifetimeID.surfaceID],
           lifetimeID.runtimeSurfaceGeneration <= watermark {
            return nil
        }
        let leaseID = UUID()
        outstandingHoverLeaseIDs[lifetimeID, default: []].insert(leaseID)
        return ExternalHoverSurfaceLease(id: leaseID, lifetimeID: lifetimeID, surface: surface)
    }

    /// Releases a lease exactly once. An unknown or already-released
    /// `leaseID` is a no-op — it must never decrement an outstanding count
    /// it doesn't actually own, which could otherwise admit a deferred
    /// free while a DIFFERENT, still-genuinely-outstanding lease exists.
    /// `async` because admitting a deferred free may itself need to
    /// `await` the isolated-hibernation admission actor.
    func releaseExternalHoverLease(_ lease: ExternalHoverSurfaceLease) async {
        guard var ids = outstandingHoverLeaseIDs[lease.lifetimeID],
              ids.remove(lease.id) != nil else {
            return
        }
        if !ids.isEmpty {
            outstandingHoverLeaseIDs[lease.lifetimeID] = ids
            return
        }
        outstandingHoverLeaseIDs.removeValue(forKey: lease.lifetimeID)
        guard let deferred = deferredHoverTeardowns.removeValue(forKey: lease.lifetimeID) else { return }
        await admitTeardown(
            deferred.request,
            executionLane: deferred.executionLane,
            isolatedHibernationReservation: deferred.isolatedHibernationReservation
        )
    }

    /// Retains the matching ExternalHover lifetime-invalidation task until its
    /// teardown request reaches admission. This closes the race where native
    /// surface teardown could otherwise run before the actor tombstones its
    /// cache and lifetime state.
    nonisolated func retainExternalHoverInvalidationTask(
        _ task: Task<Void, Never>,
        for lifetimeID: RuntimeSurfaceLifetimeID
    ) {
        externalHoverInvalidationTasks.insert(task, for: lifetimeID)
    }

    /// (C) ExternalHover diagnostics — the real production drain+log
    /// implementation `enqueueRuntimeTeardown`'s `drainDiagnostics`
    /// defaults to. `nonisolated` (an instance method, not `static`, per
    /// review B5 — it needs `self.droppedCountTracker` to linearize
    /// against the SAME per-lifetime baseline `ExternalHoverWorkService`
    /// uses, rather than reporting the ring's raw cumulative count as if
    /// it were a fresh delta every time). Safe to run on whatever thread
    /// a deferred admission happens on — the tracker is its own
    /// thread-safe type, and this makes no other coordinator-state
    /// access.
    ///
    /// Review round2 B5: `surfaceSerialRegistry` (populated by
    /// `ExternalHoverWorkService` off `request.surfaceSerial`, the ONLY
    /// place this coordinator has access to the real value — see that
    /// type's own doc) supplies the SAME numeric `surfaceSerial` the
    /// normal read/resolve/setter lines use, so this final drain's lines
    /// join on `(surfaceSerial, event)` with everything that came before
    /// it for the SAME surface, exactly as design v4's correlation-key
    /// contract requires. Falls back to `0` only if this lifetime was
    /// never registered (no request ever submitted for it — nothing to
    /// correlate either way). No separate `teardownSurfaceToken` field:
    /// the review explicitly rejected the two-scheme split this replaces.
    nonisolated func defaultDrainExternalHoverDiagnostics(
        _ surface: ghostty_surface_t,
        _ lifetimeID: RuntimeSurfaceLifetimeID
    ) {
        // Review round3 B1: unconditional cleanup via `defer` at the very
        // top — this runs on EVERY path through this function, including
        // the gate-OFF early return below, so neither tracker's entry for
        // `lifetimeID` can ever outlive this. Before this fix, cleanup
        // lived after the gate guard, so a gate-OFF teardown (the common
        // case: `swift test` never sets the env var, and most real
        // dogfood sessions run with it off too) never reached it at all —
        // every torn-down lifetime's registry/tracker entry leaked for
        // the life of the process. Safe to run unconditionally: this call
        // site (`admitTeardown`, via `enqueueRuntimeTeardown`'s default
        // `drainDiagnostics`) is provably the LAST possible report for
        // `lifetimeID` regardless of the gate — `enqueue(_:)` has already
        // confirmed no hover lease is outstanding for it, its watermark
        // bump permanently blocks any FUTURE lease acquisition for it,
        // and `freeSurface` runs immediately after this returns — so this
        // can never race a still-pending or later report the way doing it
        // from `ExternalHoverWorkService.closeLifetime` could (see that
        // method's own doc).
        defer {
            droppedCountTracker.closeLifetime(lifetimeID)
            surfaceSerialRegistry.closeLifetime(lifetimeID)
        }
        // Review round3 B4: the injected gate, not the static
        // `ExternalHoverDiagnosticsGate.isEnabled` directly — matches
        // `ExternalHoverWorkService`'s own gates, and is what lets a test
        // observe this function's real formatter/log path without the
        // real process-wide env var.
        guard diagnosticsEnabled() else { return }
        let (entries, droppedCumulative) = drainExternalHoverRing(surface)
        let droppedDelta = droppedCountTracker.reportAndComputeDelta(
            lifetimeID: lifetimeID, cumulative: droppedCumulative
        )
        let surfaceSerial = surfaceSerialRegistry.serial(for: lifetimeID) ?? 0
#if DEBUG
        for entry in entries {
            logDebugEvent("link.externalHover.diag " + entry.describeLine(surfaceSerial: surfaceSerial))
        }
        if droppedDelta > 0 {
            logDebugEvent(
                "link.externalHover stage=ghosttyDiag event=none aggregate=true droppedDelta=\(droppedDelta) " +
                "teardown=true surfaceSerial=\(surfaceSerial)"
            )
        }
#endif
    }

    /// Reads a bounded screen tail away from the main actor and before any
    /// subsequently enqueued native free for the same surface.
    ///
    /// The request performs no suspension while it holds the borrowed pointer;
    /// actor serialization therefore makes the read and a later free mutually
    /// exclusive.
    func readScreenTailVT(_ request: TerminalSurfaceRuntimeScreenTailRequest) -> String? {
        request.read()
    }

    /// Queues a native-surface free from any isolation (the surface model's
    /// `deinit` is nonisolated and cannot await).
    ///
    /// - Parameters:
    ///   - id: The owning surface id.
    ///   - workspaceId: The owning workspace id.
    ///   - reason: The teardown reason, for diagnostics.
    ///   - surface: The native surface pointer, already removed from all
    ///     main-thread owner state.
    ///   - callbackContext: The retained callback context released on the
    ///     main actor after the free completes.
    ///   - freeSurface: The free operation; defaults to
    ///     `ghostty_surface_free`.
    /// - Returns: A ticket that completes after the native free and userdata releases.
    @discardableResult
    public nonisolated func enqueueRuntimeTeardown(
        id: UUID,
        workspaceId: UUID,
        reason: String,
        surface: ghostty_surface_t,
        runtimeSurfaceGeneration: UInt64,
        callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?,
        freeSurface: @escaping @Sendable (ghostty_surface_t) -> Void = { surface in
            ghostty_surface_free(surface)
        },
        drainDiagnostics: (@Sendable (ghostty_surface_t, RuntimeSurfaceLifetimeID) -> Void)? = nil
    ) -> TerminalSurfaceRuntimeTeardownTicket {
        enqueueRuntimeTeardown(
            id: id,
            workspaceId: workspaceId,
            reason: reason,
            surface: surface,
            runtimeSurfaceGeneration: runtimeSurfaceGeneration,
            callbackContext: callbackContext,
            manualIOContext: nil,
            byteTeeLease: nil,
            freeSurface: freeSurface,
            drainDiagnostics: drainDiagnostics
        )
    }

    /// Queues a native-surface free that also transports the surface's other
    /// retained callback userdata.
    ///
    /// `ghostty_surface_free` is the synchronization point that joins
    /// ghostty's IO threads: the io-reader thread fires the PTY tee callback
    /// and the io thread fires the MANUAL-mode `io_write_cb` right up until
    /// the free returns. Transporting the manual IO context and the byte-tee
    /// lease through the request keeps their userdata retained across that
    /// window; the coordinator releases them only after the free completes,
    /// so no in-flight callback can dereference freed userdata.
    ///
    /// - Parameters:
    ///   - id: The owning surface id.
    ///   - workspaceId: The owning workspace id.
    ///   - reason: The teardown reason, for diagnostics.
    ///   - surface: The native surface pointer, already removed from all
    ///     main-thread owner state.
    ///   - callbackContext: The retained callback context released on the
    ///     main actor after the free completes.
    ///   - manualIOContext: The retained MANUAL-mode `io_write_cb` userdata,
    ///     released on the main actor after the free completes.
    ///   - byteTeeLease: The retained PTY tee lease, released on the main
    ///     actor after the free completes.
    ///   - freeSurface: The free operation; defaults to
    ///     `ghostty_surface_free`.
    /// - Returns: A ticket that completes after the native free and userdata releases.
    @discardableResult
    nonisolated func enqueueRuntimeTeardown(
        id: UUID,
        workspaceId: UUID,
        reason: String,
        surface: ghostty_surface_t,
        runtimeSurfaceGeneration: UInt64,
        callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?,
        manualIOContext: Unmanaged<TerminalManualIOWriteBox>?,
        byteTeeLease: (any TerminalByteTeeLease)?,
        executionLane: TerminalSurfaceRuntimeTeardownExecutionLane = .boundedClose,
        isolatedHibernationReservation:
            TerminalSurfaceRuntimeTeardownReservation? = nil,
        freeSurface: @escaping @Sendable (ghostty_surface_t) -> Void = { surface in
            ghostty_surface_free(surface)
        },
        drainDiagnostics: (@Sendable (ghostty_surface_t, RuntimeSurfaceLifetimeID) -> Void)? = nil
    ) -> TerminalSurfaceRuntimeTeardownTicket {
        let completion = TerminalSurfaceRuntimeTeardownCompletion()
        let ticket = TerminalSurfaceRuntimeTeardownTicket(completion: completion)
        // (C) diagnostics — review B5: the default can't be expressed as
        // a plain default-parameter value (it needs `self.
        // droppedCountTracker`, and default expressions can't reference
        // `self`), so it's resolved here instead, once per call.
        let resolvedDrainDiagnostics = drainDiagnostics ?? { [weak self] surface, lifetimeID in
            self?.defaultDrainExternalHoverDiagnostics(surface, lifetimeID)
        }
        let request = TerminalSurfaceRuntimeTeardownRequest(
            id: id,
            workspaceId: workspaceId,
            reason: reason,
            surface: surface,
            runtimeSurfaceGeneration: runtimeSurfaceGeneration,
            callbackContext: callbackContext,
            manualIOContext: manualIOContext,
            byteTeeLease: byteTeeLease,
            freeSurface: freeSurface,
            drainDiagnostics: resolvedDrainDiagnostics,
            completion: completion
        )
        Task {
            await self.enqueue(
                request,
                executionLane: executionLane,
                isolatedHibernationReservation: isolatedHibernationReservation
            )
        }
        return ticket
    }

    /// cmux fork: (B) ExternalHover — the lease gate. Every native free
    /// (close/deinit/hibernation, and any future teardown source) funnels
    /// through here, so this is the ONE place that decides whether a free
    /// may proceed now or must wait for outstanding hover leases to
    /// release (review Blocking 1: "all native free must go through the
    /// lease gate" — the audited call sites are enumerated in this
    /// commit's message).
    func enqueue(
        _ request: TerminalSurfaceRuntimeTeardownRequest,
        executionLane: TerminalSurfaceRuntimeTeardownExecutionLane = .boundedClose,
        isolatedHibernationReservation:
            TerminalSurfaceRuntimeTeardownReservation? = nil
    ) async {
        let lifetimeID = request.lifetimeID
        if let invalidationTask = externalHoverInvalidationTasks.remove(for: lifetimeID) {
            await invalidationTask.value
        }
        retiredRuntimeGenerationWatermark[lifetimeID.surfaceID] = max(
            retiredRuntimeGenerationWatermark[lifetimeID.surfaceID] ?? 0,
            lifetimeID.runtimeSurfaceGeneration
        )
        if let outstanding = outstandingHoverLeaseIDs[lifetimeID], !outstanding.isEmpty {
            if deferredHoverTeardowns[lifetimeID] != nil {
                // Two teardown requests for the SAME still-outstanding
                // lifetime — should never happen (deinit/teardown/hibernation
                // each run at most once per lifetime). Fail closed: never
                // silently overwrite and orphan the first request's
                // completion/ticket. Caught in DEBUG via assert; in release
                // this drops the second request rather than double-admitting
                // or double-freeing. Complete the second request's transport
                // envelope before returning so it cannot leak userdata or
                // leave its ticket waiting forever.
                assert(false, "duplicate teardown request for the same runtime lifetime \(lifetimeID)")
                await finishFree(request)
                return
            }
            deferredHoverTeardowns[lifetimeID] = DeferredRuntimeTeardown(
                request: request,
                executionLane: executionLane,
                isolatedHibernationReservation: isolatedHibernationReservation
            )
            return
        }
        await admitTeardown(
            request,
            executionLane: executionLane,
            isolatedHibernationReservation: isolatedHibernationReservation
        )
    }

    private func admitTeardown(
        _ request: TerminalSurfaceRuntimeTeardownRequest,
        executionLane: TerminalSurfaceRuntimeTeardownExecutionLane = .boundedClose,
        isolatedHibernationReservation:
            TerminalSurfaceRuntimeTeardownReservation? = nil
    ) async {
        // (C) ExternalHover diagnostics — design v4 §3.4's "clear/
        // teardown" trigger: the final drain, strictly BEFORE this
        // function's every path eventually calls `freeSurface`, never
        // after. `admitTeardown` is the ONE place every teardown source
        // (close/deinit/hibernation) funnels through — see the type doc
        // above — so this is also the one place the final drain needs to
        // live for every source to get it.
        request.drainDiagnostics(request.surface, request.lifetimeID)
        pendingReasonsById[request.id] = request.reason
        switch executionLane {
        case .isolatedHibernation:
            if let isolatedHibernationReservation,
               let executionSlot = await isolatedHibernationAdmission.executionSlot(
                   for: isolatedHibernationReservation
               ),
               isolatedHibernationQueues.indices.contains(executionSlot) {
                // Each reservation exclusively owns one queue until its native free
                // returns. Ghostty locks its shared surface registry, while renderer
                // and IO joins are surface-owned, so separate surfaces may tear down
                // concurrently. This bounds blocked native workers at two without
                // letting one stuck pane strand another admitted pane.
                await Self.invalidateRuntimeClipboardRequestsBeforeFree(request)
                Task {
                    await self.observeTimeout(id: request.id)
                }
                isolatedHibernationQueues[executionSlot].async {
                    self.freeNativeSurface(request)
                    Task {
                        await self.isolatedHibernationAdmission.release(
                            isolatedHibernationReservation
                        )
                        await self.finishFree(request)
                        await self.complete(id: request.id)
                    }
                }
                return
            }
            if let isolatedHibernationReservation {
                await isolatedHibernationAdmission.release(
                    isolatedHibernationReservation
                )
            }
        case .boundedClose:
            break
        }
        await Self.invalidateRuntimeClipboardRequestsBeforeFree(request)
        queuedCloseRequests.append(request)
        startAvailableCloseTeardowns()
    }

    private func startAvailableCloseTeardowns() {
        while !queuedCloseRequests.isEmpty,
              let executionSlot = availableCloseExecutionSlots.min() {
            availableCloseExecutionSlots.remove(executionSlot)
            let request = queuedCloseRequests.removeFirst()
            Task {
                await self.observeTimeout(id: request.id)
            }
            closeTeardownQueues[executionSlot].async {
                self.freeNativeSurface(request)
                Task {
                    await self.finishCloseTeardown(
                        request,
                        executionSlot: executionSlot
                    )
                }
            }
        }
    }

    private func finishCloseTeardown(
        _ request: TerminalSurfaceRuntimeTeardownRequest,
        executionSlot: Int
    ) async {
        await finishFree(request)
        complete(id: request.id)
        availableCloseExecutionSlots.insert(executionSlot)
        startAvailableCloseTeardowns()
    }

    private nonisolated static func invalidateRuntimeClipboardRequestsBeforeFree(
        _ request: TerminalSurfaceRuntimeTeardownRequest
    ) async {
        if request.callbackContext != nil {
            await MainActor.run {
                request.callbackContext?.takeUnretainedValue()
                    .invalidateRuntimeClipboardRequests(
                        completingNativeRequests: true
                    )
            }
        }
    }

    private nonisolated func freeNativeSurface(
        _ request: TerminalSurfaceRuntimeTeardownRequest
    ) {
#if DEBUG
        logDebugEvent(
            "surface.lifecycle.nativeFree.begin surface=\(request.surfaceToken) " +
            "workspace=\(request.workspaceToken) reason=\(request.reason)"
        )
#endif
        request.freeSurface(request.surface)
    }

    private nonisolated func finishFree(
        _ request: TerminalSurfaceRuntimeTeardownRequest
    ) async {
        if request.callbackContext != nil || request.manualIOContext != nil || request.byteTeeLease != nil {
            // The request is the @unchecked Sendable transport for the
            // Unmanaged contexts; release through the request so the @Sendable
            // closure never captures the non-Sendable Unmanaged directly.
            // Ordered after freeSurface: the native free joins ghostty's IO
            // threads, so no tee/io_write callback can still hold this
            // userdata. The byte-tee lease goes last so tests can use its
            // release as the "all userdata released" beacon.
            await MainActor.run {
                request.callbackContext?.release()
                request.manualIOContext?.release()
                request.byteTeeLease?.release()
            }
        }
        await request.completion.finish()
#if DEBUG
        logDebugEvent(
            "surface.lifecycle.nativeFree.end surface=\(request.surfaceToken) " +
            "workspace=\(request.workspaceToken) reason=\(request.reason)"
        )
#endif
    }

    private func complete(id: UUID) {
        pendingReasonsById.removeValue(forKey: id)
    }

    private func observeTimeout(id: UUID) async {
        do {
            // Genuine teardown deadline: report a stuck native free without blocking close.
            try await Task.sleep(for: timeout)
        } catch {
            return
        }
        guard let reason = pendingReasonsById[id] else { return }
#if DEBUG
        logDebugEvent(
            "surface.lifecycle.nativeFree.timeout surface=\(id.uuidString.prefix(5)) " +
            "reason=\(reason)"
        )
#endif
    }
}
