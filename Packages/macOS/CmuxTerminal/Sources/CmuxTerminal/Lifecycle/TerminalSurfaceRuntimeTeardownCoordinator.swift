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

    /// Creates the process's teardown coordinator.
    public init() {
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
    ///   - beforeFree: An asynchronous fence awaited before `freeSurface` is
    ///     scheduled. Defaults to an already-complete fence.
    ///   - freeSurface: The free operation; defaults to
    ///     `ghostty_surface_free`.
    /// - Returns: A ticket that completes after the native free and userdata releases.
    @discardableResult
    public nonisolated func enqueueRuntimeTeardown(
        id: UUID,
        workspaceId: UUID,
        reason: String,
        surface: ghostty_surface_t,
        callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?,
        beforeFree: @escaping @Sendable () async -> Void = {},
        freeSurface: @escaping @Sendable (ghostty_surface_t) -> Void = { surface in
            ghostty_surface_free(surface)
        }
    ) -> TerminalSurfaceRuntimeTeardownTicket {
        enqueueRuntimeTeardown(
            id: id,
            workspaceId: workspaceId,
            reason: reason,
            surface: surface,
            callbackContext: callbackContext,
            manualIOContext: nil,
            byteTeeLease: nil,
            beforeFree: beforeFree,
            freeSurface: freeSurface
        )
    }

    /// Enqueues an asynchronous lifecycle fence without freeing a native surface.
    ///
    /// This is used when a wrapper has already observed an out-of-band native
    /// free: retained callback userdata still needs a joinable lane fence, but
    /// calling `ghostty_surface_free` again would be invalid.
    ///
    /// - Parameters:
    ///   - id: A unique teardown-operation id used for timeout bookkeeping.
    ///   - workspaceId: The owning workspace id for diagnostics.
    ///   - reason: The teardown reason for diagnostics.
    ///   - fence: The asynchronous operation that must finish first.
    ///   - onCompletion: Main-actor cleanup performed after the fence.
    /// - Returns: A ticket that completes after the fence and cleanup.
    @discardableResult
    nonisolated func enqueueRuntimeTeardownFence(
        id: UUID,
        workspaceId: UUID,
        reason: String,
        fence: @escaping @Sendable () async -> Void,
        onCompletion: @escaping @MainActor @Sendable () -> Void
    ) -> TerminalSurfaceRuntimeTeardownTicket {
        let completion = TerminalSurfaceRuntimeTeardownCompletion()
        let ticket = TerminalSurfaceRuntimeTeardownTicket(completion: completion)
        Task {
            await self.enqueueRuntimeTeardownFence(
                id: id,
                workspaceId: workspaceId,
                reason: reason,
                fence: fence,
                onCompletion: onCompletion,
                completion: completion
            )
        }
        return ticket
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
    ///   - beforeFree: An asynchronous fence awaited before `freeSurface` is
    ///     scheduled. Defaults to an already-complete fence.
    ///   - freeSurface: The free operation; defaults to
    ///     `ghostty_surface_free`.
    /// - Returns: A ticket that completes after the native free and userdata releases.
    @discardableResult
    nonisolated func enqueueRuntimeTeardown(
        id: UUID,
        workspaceId: UUID,
        reason: String,
        surface: ghostty_surface_t,
        callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?,
        manualIOContext: Unmanaged<TerminalManualIOWriteBox>?,
        byteTeeLease: (any TerminalByteTeeLease)?,
        beforeFree: @escaping @Sendable () async -> Void = {},
        executionLane: TerminalSurfaceRuntimeTeardownExecutionLane = .boundedClose,
        isolatedHibernationReservation:
            TerminalSurfaceRuntimeTeardownReservation? = nil,
        freeSurface: @escaping @Sendable (ghostty_surface_t) -> Void = { surface in
            ghostty_surface_free(surface)
        }
    ) -> TerminalSurfaceRuntimeTeardownTicket {
        let completion = TerminalSurfaceRuntimeTeardownCompletion()
        let ticket = TerminalSurfaceRuntimeTeardownTicket(completion: completion)
        let request = TerminalSurfaceRuntimeTeardownRequest(
            id: id,
            workspaceId: workspaceId,
            reason: reason,
            surface: surface,
            callbackContext: callbackContext,
            manualIOContext: manualIOContext,
            byteTeeLease: byteTeeLease,
            beforeFree: beforeFree,
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
                let completion: @Sendable () -> Void = { [self] in
                    Task {
                        await self.isolatedHibernationAdmission.release(
                            isolatedHibernationReservation
                        )
                        await self.finishFree(request)
                        await self.complete(id: request.id)
                    }
                }
                Self.scheduleNativeFree(
                    request,
                    on: isolatedHibernationQueues[executionSlot],
                    completion: completion
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
        await Self.invalidateRuntimeClipboardRequestsBeforeFree(request)
        queuedCloseRequests.append(request)
        startAvailableCloseTeardowns()
    }

    private func enqueueRuntimeTeardownFence(
        id: UUID,
        workspaceId: UUID,
        reason: String,
        fence: @escaping @Sendable () async -> Void,
        onCompletion: @escaping @MainActor @Sendable () -> Void,
        completion: TerminalSurfaceRuntimeTeardownCompletion
    ) async {
        pendingReasonsById[id] =
            "\(reason) workspace=\(workspaceId.uuidString.prefix(5))"
        Task {
            await self.observeTimeout(id: id)
        }
        await fence()
        await onCompletion()
        await completion.finish()
        complete(id: id)
    }

    private func startAvailableCloseTeardowns() {
        while !queuedCloseRequests.isEmpty,
              let executionSlot = availableCloseExecutionSlots.min() {
            availableCloseExecutionSlots.remove(executionSlot)
            let request = queuedCloseRequests.removeFirst()
            Task {
                await self.observeTimeout(id: request.id)
            }
            let completion: @Sendable () -> Void = { [self] in
                Task {
                    await self.finishCloseTeardown(
                        request,
                        executionSlot: executionSlot
                    )
                }
            }
            Self.scheduleNativeFree(
                request,
                on: closeTeardownQueues[executionSlot],
                completion: completion
            )
        }
    }

    /// Awaits the lane fence without blocking a native-free worker, then starts
    /// the bounded native-free operation on that worker's queue.
    private nonisolated static func scheduleNativeFree(
        _ request: TerminalSurfaceRuntimeTeardownRequest,
        on queue: DispatchQueue,
        completion: @escaping @Sendable () -> Void
    ) {
        Task {
            await request.beforeFree()
            queue.async {
                Self.freeNativeSurface(request)
                completion()
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

    private nonisolated static func freeNativeSurface(
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
