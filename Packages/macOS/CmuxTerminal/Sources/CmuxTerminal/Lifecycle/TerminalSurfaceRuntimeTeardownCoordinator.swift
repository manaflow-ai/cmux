public import Foundation
public import GhosttyKit
public import CmuxTerminalCore
#if DEBUG
internal import CMUXDebugLog
#endif

/// Coordinates native `ghostty_surface_free` calls off the close/deinit paths.
///
/// Close/deinit frees use two independently startable utility slots. Each slot
/// remains serial, so teardown cannot recursively reuse one worker, while one
/// stuck native join leaves the other slot available to drain later closes.
/// Every native surface holds a bounded ownership reservation from creation
/// through completed free. While both close slots are occupied, new ownership
/// waits for a worker-completion signal, so retained frees cannot grow without
/// bound.
/// Each admitted hibernation also owns one independently startable utility slot.
/// Slot occupancy fences new ownership until one active free completes. The app constructs
/// exactly one instance and injects it through
/// ``TerminalSurfaceRuntimeDependencies``.
public actor TerminalSurfaceRuntimeTeardownCoordinator {
    /// Maximum native close frees that can run concurrently.
    public static let maximumConcurrentCloseTeardownCount = 2

    /// Maximum live plus retained native surfaces owned by one coordinator.
    public static let maximumRuntimeSurfaceOwnerCount = 4_096

    /// Largest batch that can own independently startable native-free slots.
    public static let maximumIsolatedHibernationTeardownCount = 2

    private nonisolated let submissionDrain:
        TerminalSurfaceRuntimeTeardownSubmissionDrain
    private nonisolated let recoveryRescanScheduler:
        TerminalSurfaceRuntimeOwnershipRecoveryRescanScheduler
#if DEBUG
    // Readable at internal scope in DEBUG so the debug-only extension in
    // TerminalSurfaceRuntimeTeardownCoordinator+Debug.swift can report the
    // pending count; private in release builds.
    var pendingRequestsById: [UUID: (surfaceID: UUID, reason: String)] = [:]
#else
    private var pendingRequestsById: [UUID: (surfaceID: UUID, reason: String)] = [:]
#endif
    private var queuedCloseRequests: [TerminalSurfaceRuntimeTeardownRequest] = []
    private var availableCloseExecutionSlots: Set<Int>
    private var activeCloseTeardownsBySlot:
        [Int: TerminalSurfaceRuntimeActiveTeardown] = [:]
    private var activeHibernationTeardownsBySlot:
        [Int: TerminalSurfaceRuntimeActiveTeardown] = [:]
    private var cancelledTicketIDs: Set<UUID> = []
#if DEBUG
    // Readable at internal scope in DEBUG so the debug-only extension in
    // TerminalSurfaceRuntimeTeardownCoordinator+Debug.swift can report
    // admission health; private in release builds.
    nonisolated let runtimeOwnershipAdmission:
        TerminalSurfaceRuntimeOwnershipAdmission
#else
    private nonisolated let runtimeOwnershipAdmission:
        TerminalSurfaceRuntimeOwnershipAdmission
#endif
    private nonisolated let isolatedHibernationAdmission =
        TerminalSurfaceRuntimeTeardownAdmission()

    /// Creates the process's teardown coordinator.
    public init() {
        let recoveryRescanScheduler =
            TerminalSurfaceRuntimeOwnershipRecoveryRescanScheduler(
                maximumEntryCount: Self.maximumRuntimeSurfaceOwnerCount
            )
        submissionDrain = TerminalSurfaceRuntimeTeardownSubmissionDrain(
            maximumBufferedOperationCount:
                Self.maximumRuntimeSurfaceOwnerCount
        )
        runtimeOwnershipAdmission = TerminalSurfaceRuntimeOwnershipAdmission(
            maximumOwnerCount: Self.maximumRuntimeSurfaceOwnerCount,
            recoveryRescanScheduler: recoveryRescanScheduler
        )
        self.recoveryRescanScheduler = recoveryRescanScheduler
        availableCloseExecutionSlots = Set(
            0..<Self.maximumConcurrentCloseTeardownCount
        )
    }

    init(maximumRuntimeSurfaceOwnerCount: Int) {
        let recoveryRescanScheduler =
            TerminalSurfaceRuntimeOwnershipRecoveryRescanScheduler(
                maximumEntryCount: maximumRuntimeSurfaceOwnerCount
            )
        submissionDrain = TerminalSurfaceRuntimeTeardownSubmissionDrain(
            maximumBufferedOperationCount:
                maximumRuntimeSurfaceOwnerCount
        )
        runtimeOwnershipAdmission = TerminalSurfaceRuntimeOwnershipAdmission(
            maximumOwnerCount: maximumRuntimeSurfaceOwnerCount,
            recoveryRescanScheduler: recoveryRescanScheduler
        )
        self.recoveryRescanScheduler = recoveryRescanScheduler
        availableCloseExecutionSlots = Set(
            0..<Self.maximumConcurrentCloseTeardownCount
        )
    }

    deinit {
        for active in activeCloseTeardownsBySlot.values {
            active.task.cancel()
        }
        for active in activeHibernationTeardownsBySlot.values {
            active.task.cancel()
        }
    }

    nonisolated func reserveRuntimeSurfaceOwnership()
        -> TerminalSurfaceRuntimeOwnershipReservation? {
        runtimeOwnershipAdmission.reserve()
    }

    nonisolated func reserveRuntimeSurfaceOwnership(
        recoveryID: UUID,
        onRecovery: @escaping TerminalSurfaceRuntimeOwnershipRecovery,
        capacityReservation:
            TerminalSurfaceRuntimeOwnershipRecoveryCapacityReservation? = nil
    ) -> TerminalSurfaceRuntimeOwnershipRecoveryAdmissionResult {
        runtimeOwnershipAdmission.reserve(
            recoveryID: recoveryID,
            onRecovery: onRecovery,
            capacityReservation: capacityReservation
        )
    }

    nonisolated func registerRuntimeSurfaceOwnershipRecoveryOverflow(
        surfaceID: UUID,
        surface: TerminalSurface
    ) -> TerminalSurfaceRuntimeOwnershipRecoveryOverflowRegistration {
        recoveryRescanScheduler.registerOverflow(
            surfaceID: surfaceID,
            surface: surface
        )
    }

    nonisolated func cancelRuntimeSurfaceOwnershipRecoveryOverflow(
        surfaceID: UUID
    ) {
        recoveryRescanScheduler.cancelOverflow(surfaceID: surfaceID)
    }

    nonisolated func requestRuntimeSurfaceOwnershipRecoveryRescan() {
        recoveryRescanScheduler.requestRescan()
    }

#if DEBUG
    nonisolated var debugRuntimeSurfaceOwnershipRecoveryOverflowSnapshot: (
        entryCount: Int,
        linkedNodeCount: Int,
        headID: UUID?,
        tailID: UUID?
    ) {
        recoveryRescanScheduler.debugSnapshot
    }
#endif

    nonisolated func claimRuntimeSurfaceOwnershipRecoveryCapacity()
        -> TerminalSurfaceRuntimeOwnershipRecoveryCapacityReservation? {
        runtimeOwnershipAdmission.claimRecoveryCapacity()
    }

    nonisolated func runtimeSurfaceOwnershipRecoveryCapacityIsOpen() -> Bool {
        runtimeOwnershipAdmission.recoveryCapacityIsOpen()
    }

    nonisolated func cancelRuntimeSurfaceOwnershipRecoveryCapacity(
        _ reservation:
            TerminalSurfaceRuntimeOwnershipRecoveryCapacityReservation
    ) {
        runtimeOwnershipAdmission.releaseRecoveryCapacity(reservation)
    }

    nonisolated func cancelRuntimeSurfaceOwnershipRecovery(_ recoveryID: UUID) {
        runtimeOwnershipAdmission.cancelRecovery(recoveryID)
    }

    nonisolated func cancelRuntimeSurfaceOwnership(
        _ reservation: TerminalSurfaceRuntimeOwnershipReservation
    ) {
        runtimeOwnershipAdmission.release(reservation)
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

    /// Reads a bounded screen tail away from the main actor and before any
    /// subsequently enqueued native free for the same surface.
    ///
    /// The request performs no suspension while it holds the borrowed pointer;
    /// actor serialization therefore makes the read and a later free mutually
    /// exclusive.
    func readScreenTailVT(_ request: TerminalSurfaceRuntimeScreenTailRequest) -> String? {
        request.read()
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
    /// - Returns: A ticket that completes after the native free and userdata
    ///   releases, or `nil` when the supplied ownership reservation is invalid,
    ///   was already transferred, or the submission stream has terminated. On
    ///   `nil`, the caller retains the native pointer and its callback userdata.
    @discardableResult
    nonisolated func enqueueRuntimeTeardown(
        id: UUID,
        workspaceId: UUID,
        reason: String,
        surface: ghostty_surface_t,
        callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?,
        manualIOContext: Unmanaged<TerminalManualIOWriteBox>?,
        byteTeeLease: (any TerminalByteTeeLease)?,
        runtimeOwnershipReservation:
            TerminalSurfaceRuntimeOwnershipReservation,
        executionLane: TerminalSurfaceRuntimeTeardownExecutionLane = .boundedClose,
        isolatedHibernationReservation:
            TerminalSurfaceRuntimeTeardownReservation? = nil,
        freeSurface: @escaping @Sendable (ghostty_surface_t) -> Void = { surface in
            ghostty_surface_free(surface)
        }
    ) -> TerminalSurfaceRuntimeTeardownTicket? {
        guard let ingressReservation =
            runtimeOwnershipAdmission.claimIngressReservation(
                for: runtimeOwnershipReservation
            ) else {
            return nil
        }
        let completion = TerminalSurfaceRuntimeTeardownCompletion()
        let ticket = TerminalSurfaceRuntimeTeardownTicket(completion: completion)
        let request = TerminalSurfaceRuntimeTeardownRequest(
            ticketID: ticket.id,
            id: id,
            workspaceId: workspaceId,
            reason: reason,
            surface: surface,
            callbackContext: callbackContext,
            manualIOContext: manualIOContext,
            byteTeeLease: byteTeeLease,
            runtimeOwnershipReservation: runtimeOwnershipReservation,
            freeSurface: freeSurface,
            completion: completion
        )
        let submission = TerminalSurfaceRuntimeTeardownSubmission.enqueue(
            request: request,
            executionLane: executionLane,
            isolatedHibernationReservation: isolatedHibernationReservation,
            ingressReservation: ingressReservation
        )
        let yieldResult = submissionDrain.yield { [self] in
            await receive(submission)
        }
        switch yieldResult {
        case .enqueued:
            return ticket
        case .dropped, .terminated:
            runtimeOwnershipAdmission.releaseFailedSubmission(
                ownership: runtimeOwnershipReservation,
                ingress: ingressReservation
            )
            return nil
        @unknown default:
            runtimeOwnershipAdmission.releaseFailedSubmission(
                ownership: runtimeOwnershipReservation,
                ingress: ingressReservation
            )
            return nil
        }
    }

    /// Requests cancellation without abandoning the owned native free.
    ///
    /// Cancellation is ordered with enqueue through the same ingress. A
    /// cancelled Task still performs the non-cancellable native free and then
    /// releases its reservation through the normal completion path.
    @discardableResult
    nonisolated func cancelRuntimeTeardown(ticketID: UUID) async -> Bool {
        guard let ingressReservation =
            runtimeOwnershipAdmission.reserveControlIngress() else {
            return false
        }
        let result = AsyncStream<Bool>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let submission = TerminalSurfaceRuntimeTeardownSubmission.cancel(
            ticketID: ticketID,
            result: result.continuation,
            ingressReservation: ingressReservation
        )
        let yieldResult = submissionDrain.yield { [self] in
            await receive(submission)
        }
        switch yieldResult {
        case .enqueued:
            var iterator = result.stream.makeAsyncIterator()
            return await iterator.next() ?? false
        case .dropped, .terminated:
            runtimeOwnershipAdmission.releaseIngress(ingressReservation)
            result.continuation.finish()
            return false
        @unknown default:
            runtimeOwnershipAdmission.releaseIngress(ingressReservation)
            result.continuation.finish()
            return false
        }
    }

    nonisolated func cancelAllRuntimeTeardowns() {
        guard let ingressReservation =
            runtimeOwnershipAdmission.reserveControlIngress() else {
            return
        }
        let submission = TerminalSurfaceRuntimeTeardownSubmission.cancelAll(
            ingressReservation: ingressReservation
        )
        let yieldResult = submissionDrain.yield { [self] in
            await receive(submission)
        }
        switch yieldResult {
        case .enqueued:
            break
        case .dropped, .terminated:
            runtimeOwnershipAdmission.releaseIngress(ingressReservation)
        @unknown default:
            runtimeOwnershipAdmission.releaseIngress(ingressReservation)
        }
    }

    private func receive(
        _ submission: TerminalSurfaceRuntimeTeardownSubmission
    ) async {
        switch submission {
        case .enqueue(
            let request,
            let executionLane,
            let isolatedHibernationReservation,
            let ingressReservation
        ):
            runtimeOwnershipAdmission.releaseIngress(ingressReservation)
            await enqueue(
                request,
                executionLane: executionLane,
                isolatedHibernationReservation:
                    isolatedHibernationReservation
            )
        case .cancel(let ticketID, let result, let ingressReservation):
            runtimeOwnershipAdmission.releaseIngress(ingressReservation)
            result.yield(cancelStoredTeardown(ticketID: ticketID))
            result.finish()
        case .cancelAll(let ingressReservation):
            runtimeOwnershipAdmission.releaseIngress(ingressReservation)
            cancelAllStoredTeardowns()
        }
    }

    private func enqueue(
        _ request: TerminalSurfaceRuntimeTeardownRequest,
        executionLane: TerminalSurfaceRuntimeTeardownExecutionLane,
        isolatedHibernationReservation:
            TerminalSurfaceRuntimeTeardownReservation?
    ) async {
        pendingRequestsById[request.ticketID] = (
            surfaceID: request.id,
            reason: request.reason
        )
        switch executionLane {
        case .isolatedHibernation:
            if let isolatedHibernationReservation,
               let executionSlot = await isolatedHibernationAdmission.executionSlot(
                   for: isolatedHibernationReservation
               ),
               !activeHibernationTeardownsBySlot.keys.contains(executionSlot) {
                startTeardown(
                    request,
                    executionLane: .isolatedHibernation,
                    executionSlot: executionSlot,
                    isolatedHibernationReservation:
                        isolatedHibernationReservation
                )
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
        queuedCloseRequests.append(request)
        startAvailableCloseTeardowns()
    }

    private func startAvailableCloseTeardowns() {
        while !queuedCloseRequests.isEmpty,
              let executionSlot = availableCloseExecutionSlots.min() {
            availableCloseExecutionSlots.remove(executionSlot)
            startTeardown(
                queuedCloseRequests.removeFirst(),
                executionLane: .boundedClose,
                executionSlot: executionSlot,
                isolatedHibernationReservation: nil
            )
        }
    }

    private func startTeardown(
        _ request: TerminalSurfaceRuntimeTeardownRequest,
        executionLane: TerminalSurfaceRuntimeTeardownExecutionLane,
        executionSlot: Int,
        isolatedHibernationReservation:
            TerminalSurfaceRuntimeTeardownReservation?
    ) {
        // This method is reachable only after one of two close slots or two
        // isolated-hibernation slots is admitted, which caps worker threads at 4.
        let prepared = executionLane.prepare(
            operation: {
                self.freeNativeSurface(request)
            },
            completion: {
                await self.finishTeardown(
                    request,
                    executionLane: executionLane,
                    executionSlot: executionSlot,
                    isolatedHibernationReservation:
                        isolatedHibernationReservation
                )
            }
        )
        let active = TerminalSurfaceRuntimeActiveTeardown(
            ticketID: request.ticketID,
            task: prepared.task
        )
        switch executionLane {
        case .boundedClose:
            activeCloseTeardownsBySlot[executionSlot] = active
            updateCloseTeardownAdmission()
        case .isolatedHibernation:
            activeHibernationTeardownsBySlot[executionSlot] = active
        }
        if cancelledTicketIDs.remove(request.ticketID) != nil {
            prepared.task.cancel()
        }
        prepared.start()
    }

    private func cancelStoredTeardown(ticketID: UUID) -> Bool {
        if let active = activeCloseTeardownsBySlot.values.first(
            where: { $0.ticketID == ticketID }
        ) {
            active.task.cancel()
            return true
        }
        if let active = activeHibernationTeardownsBySlot.values.first(
            where: { $0.ticketID == ticketID }
        ) {
            active.task.cancel()
            return true
        }
        if queuedCloseRequests.contains(
            where: { $0.ticketID == ticketID }
        ) {
            cancelledTicketIDs.insert(ticketID)
            return true
        }
        return false
    }

    private func cancelAllStoredTeardowns() {
        cancelledTicketIDs.formUnion(
            queuedCloseRequests.map(\.ticketID)
        )
        for active in activeCloseTeardownsBySlot.values {
            active.task.cancel()
        }
        for active in activeHibernationTeardownsBySlot.values {
            active.task.cancel()
        }
    }

    private func finishTeardown(
        _ request: TerminalSurfaceRuntimeTeardownRequest,
        executionLane: TerminalSurfaceRuntimeTeardownExecutionLane,
        executionSlot: Int,
        isolatedHibernationReservation:
            TerminalSurfaceRuntimeTeardownReservation?
    ) async {
        let active: TerminalSurfaceRuntimeActiveTeardown?
        switch executionLane {
        case .boundedClose:
            active = activeCloseTeardownsBySlot[executionSlot]
        case .isolatedHibernation:
            active = activeHibernationTeardownsBySlot[executionSlot]
        }
        guard active?.ticketID == request.ticketID else { return }

        switch executionLane {
        case .boundedClose:
            activeCloseTeardownsBySlot.removeValue(forKey: executionSlot)
        case .isolatedHibernation:
            activeHibernationTeardownsBySlot.removeValue(forKey: executionSlot)
        }

        await finishFree(request)
        complete(requestID: request.ticketID)

        switch executionLane {
        case .boundedClose:
            availableCloseExecutionSlots.insert(executionSlot)
            updateCloseTeardownAdmission()
            startAvailableCloseTeardowns()
        case .isolatedHibernation:
            if let isolatedHibernationReservation {
                await isolatedHibernationAdmission.release(
                    isolatedHibernationReservation
                )
            }
        }
    }

    private func updateCloseTeardownAdmission() {
        runtimeOwnershipAdmission.setCloseTeardownDegraded(
            activeCloseTeardownsBySlot.count
                == Self.maximumConcurrentCloseTeardownCount
        )
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
        runtimeOwnershipAdmission.release(
            request.runtimeOwnershipReservation
        )
        await request.completion.finish()
#if DEBUG
        logDebugEvent(
            "surface.lifecycle.nativeFree.end surface=\(request.surfaceToken) " +
            "workspace=\(request.workspaceToken) reason=\(request.reason)"
        )
#endif
    }

    private func complete(requestID: UUID) {
        pendingRequestsById.removeValue(forKey: requestID)
    }

}
