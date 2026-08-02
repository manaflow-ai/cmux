public import Foundation
public import GhosttyKit
public import CmuxTerminalCore
internal import Dispatch
#if DEBUG
internal import CMUXDebugLog
#endif

/// Coordinates native `ghostty_surface_free` calls off the close/deinit paths.
///
/// Close/deinit frees use two independently startable utility slots. Each slot
/// remains serial, so teardown cannot recursively reuse one worker, while one
/// stuck native join leaves the other slot available to drain later closes.
/// Every native surface holds a bounded ownership reservation from creation
/// through completed free. If both close workers time out, new ownership is
/// rejected until a worker recovers, so retained frees cannot grow without
/// bound.
/// Each admitted hibernation also owns one independently startable utility slot.
/// Deadline observers report, but never block on, stuck frees. The app constructs
/// exactly one instance and injects it through
/// ``TerminalSurfaceRuntimeDependencies``.
public actor TerminalSurfaceRuntimeTeardownCoordinator {
    /// Maximum native close frees that can run concurrently.
    public static let maximumConcurrentCloseTeardownCount = 2

    /// Maximum live plus retained native surfaces owned by one coordinator.
    public static let maximumRuntimeSurfaceOwnerCount = 4_096

    /// Largest batch that can own independently startable native-free slots.
    public static let maximumIsolatedHibernationTeardownCount = 2

    private let closeTeardownTimeout: Duration
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
    private var timedOutCloseExecutionSlots: Set<Int> = []
    private let closeTeardownQueues: [DispatchQueue]
    private let isolatedHibernationQueues: [DispatchQueue]
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
        closeTeardownTimeout = .seconds(5)
        runtimeOwnershipAdmission = TerminalSurfaceRuntimeOwnershipAdmission(
            maximumOwnerCount: Self.maximumRuntimeSurfaceOwnerCount
        )
        availableCloseExecutionSlots = Set(
            0..<Self.maximumConcurrentCloseTeardownCount
        )
        closeTeardownQueues = Self.makeCloseTeardownQueues()
        isolatedHibernationQueues = Self.makeIsolatedHibernationQueues()
    }

    init(
        closeTeardownTimeout: Duration,
        maximumRuntimeSurfaceOwnerCount: Int
    ) {
        precondition(closeTeardownTimeout > .zero)
        self.closeTeardownTimeout = closeTeardownTimeout
        runtimeOwnershipAdmission = TerminalSurfaceRuntimeOwnershipAdmission(
            maximumOwnerCount: maximumRuntimeSurfaceOwnerCount
        )
        availableCloseExecutionSlots = Set(
            0..<Self.maximumConcurrentCloseTeardownCount
        )
        closeTeardownQueues = Self.makeCloseTeardownQueues()
        isolatedHibernationQueues = Self.makeIsolatedHibernationQueues()
    }

    private nonisolated static func makeCloseTeardownQueues() -> [DispatchQueue] {
        (
            0..<Self.maximumConcurrentCloseTeardownCount
        ).map { executionSlot in
            DispatchQueue(
                label: "com.cmux.terminal-surface-close-teardown.\(executionSlot)",
                qos: .utility
            )
        }
    }

    private nonisolated static func makeIsolatedHibernationQueues()
        -> [DispatchQueue] {
        (
            0..<Self.maximumIsolatedHibernationTeardownCount
        ).map { executionSlot in
            DispatchQueue(
                label: "com.cmux.terminal-surface-hibernation-teardown.\(executionSlot)",
                qos: .utility
            )
        }
    }

    nonisolated func reserveRuntimeSurfaceOwnership()
        -> TerminalSurfaceRuntimeOwnershipReservation? {
        runtimeOwnershipAdmission.reserve()
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
    /// - Returns: A ticket that completes after the native free and userdata
    ///   releases, or `nil` when bounded ownership admission is unavailable.
    ///   On `nil`, the caller retains the native pointer and callback userdata.
    @discardableResult
    public nonisolated func enqueueRuntimeTeardown(
        id: UUID,
        workspaceId: UUID,
        reason: String,
        surface: ghostty_surface_t,
        callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?,
        freeSurface: @escaping @Sendable (ghostty_surface_t) -> Void = { surface in
            ghostty_surface_free(surface)
        }
    ) -> TerminalSurfaceRuntimeTeardownTicket? {
        enqueueRuntimeTeardown(
            id: id,
            workspaceId: workspaceId,
            reason: reason,
            surface: surface,
            callbackContext: callbackContext,
            manualIOContext: nil,
            byteTeeLease: nil,
            freeSurface: freeSurface
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
    /// - Returns: A ticket that completes after the native free and userdata
    ///   releases, or `nil` when bounded ownership admission is degraded or
    ///   exhausted. On `nil`, the caller retains the native pointer and its
    ///   callback userdata.
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
            TerminalSurfaceRuntimeOwnershipReservation? = nil,
        executionLane: TerminalSurfaceRuntimeTeardownExecutionLane = .boundedClose,
        isolatedHibernationReservation:
            TerminalSurfaceRuntimeTeardownReservation? = nil,
        freeSurface: @escaping @Sendable (ghostty_surface_t) -> Void = { surface in
            ghostty_surface_free(surface)
        }
    ) -> TerminalSurfaceRuntimeTeardownTicket? {
        let admittedRuntimeOwnership: TerminalSurfaceRuntimeOwnershipReservation
        if let existing = runtimeOwnershipReservation {
            guard runtimeOwnershipAdmission.contains(existing) else { return nil }
            admittedRuntimeOwnership = existing
        } else {
            guard let admitted = runtimeOwnershipAdmission.reserve() else { return nil }
            admittedRuntimeOwnership = admitted
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
            runtimeOwnershipReservation: admittedRuntimeOwnership,
            freeSurface: freeSurface,
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

    func enqueue(
        _ request: TerminalSurfaceRuntimeTeardownRequest,
        executionLane: TerminalSurfaceRuntimeTeardownExecutionLane = .boundedClose,
        isolatedHibernationReservation:
            TerminalSurfaceRuntimeTeardownReservation? = nil
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
               isolatedHibernationQueues.indices.contains(executionSlot) {
                // Each reservation exclusively owns one queue until its native free
                // returns. Ghostty locks its shared surface registry, while renderer
                // and IO joins are surface-owned, so separate surfaces may tear down
                // concurrently. This bounds blocked native workers at two without
                // letting one stuck pane strand another admitted pane.
                Task {
                    await self.observeTimeout(requestID: request.ticketID)
                }
                isolatedHibernationQueues[executionSlot].async {
                    self.freeNativeSurface(request)
                    Task {
                        await self.isolatedHibernationAdmission.release(
                            isolatedHibernationReservation
                        )
                        await self.finishFree(request)
                        await self.complete(requestID: request.ticketID)
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
        queuedCloseRequests.append(request)
        scheduleCloseTeardowns()
    }

    private func scheduleCloseTeardowns() {
        while !queuedCloseRequests.isEmpty,
              let executionSlot = availableCloseExecutionSlots.min() {
            availableCloseExecutionSlots.remove(executionSlot)
            let request = queuedCloseRequests.removeFirst()
            Task {
                await self.observeTimeout(
                    requestID: request.ticketID,
                    closeExecutionSlot: executionSlot
                )
            }
            closeTeardownQueues[executionSlot].async {
                self.freeNativeSurface(request)
                Task {
                    await self.finishFree(request)
                    await self.complete(requestID: request.ticketID)
                    await self.closeTeardownFinished(executionSlot: executionSlot)
                }
            }
        }
    }

    private func closeTeardownFinished(executionSlot: Int) {
        timedOutCloseExecutionSlots.remove(executionSlot)
        if timedOutCloseExecutionSlots.count
            < Self.maximumConcurrentCloseTeardownCount {
            runtimeOwnershipAdmission.setCloseTeardownDegraded(false)
        }
        availableCloseExecutionSlots.insert(executionSlot)
        scheduleCloseTeardowns()
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

    private func observeTimeout(
        requestID: UUID,
        closeExecutionSlot: Int? = nil
    ) async {
        do {
            // Genuine teardown deadline: report a stuck native free without blocking close.
            try await Task.sleep(for: closeTeardownTimeout)
        } catch {
            return
        }
        guard let pending = pendingRequestsById[requestID] else { return }
        if let closeExecutionSlot {
            timedOutCloseExecutionSlots.insert(closeExecutionSlot)
            if timedOutCloseExecutionSlots.count
                == Self.maximumConcurrentCloseTeardownCount {
                runtimeOwnershipAdmission.setCloseTeardownDegraded(true)
            }
        }
#if DEBUG
        logDebugEvent(
            "surface.lifecycle.nativeFree.timeout surface=\(pending.surfaceID.uuidString.prefix(5)) " +
            "reason=\(pending.reason)"
        )
#endif
    }
}
