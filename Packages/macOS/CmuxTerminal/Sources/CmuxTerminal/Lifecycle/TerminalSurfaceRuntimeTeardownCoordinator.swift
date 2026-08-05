public import Foundation
public import GhosttyKit
public import CmuxTerminalCore
internal import Dispatch
#if DEBUG
internal import CMUXDebugLog
#endif

/// Coordinates every native surface creation, borrowed read, and free.
///
/// Native operations drain through one process-wide queue. Creation executes on
/// the main actor because it reads AppKit view state. Bounded reads and blocking
/// frees execute on one utility worker. The queue never starts the next operation
/// until the current operation returns, so `ghostty_surface_new`, borrowed native
/// reads, and `ghostty_surface_free` cannot overlap. Deadline observers report,
/// but never block the main actor on, stuck frees. The app constructs exactly one
/// instance and injects it through
/// ``TerminalSurfaceRuntimeDependencies``.
public actor TerminalSurfaceRuntimeTeardownCoordinator {
    /// Largest hibernation batch that can reserve pending native teardowns.
    public static let maximumHibernationTeardownCount = 2

    private let timeout: Duration = .seconds(5)
    private let timeoutClock: any Clock<Duration>
#if DEBUG
    // Readable at internal scope in DEBUG so the debug-only extension in
    // TerminalSurfaceRuntimeTeardownCoordinator+Debug.swift can report the
    // pending count; private in release builds.
    var pendingReasonsById: [UUID: String] = [:]
#else
    private var pendingReasonsById: [UUID: String] = [:]
#endif
    private var queuedOperations: [TerminalSurfaceRuntimeNativeOperation] = []
    private var nextQueuedOperationIndex = 0
    private var isWorkerRunning = false
    private nonisolated let nativeWorkerQueue: DispatchQueue
    private nonisolated let hibernationAdmission =
        TerminalSurfaceRuntimeTeardownAdmission()

    /// Creates the process's native surface lifecycle coordinator.
    ///
    /// - Parameter timeoutClock: Clock used for stuck-free reporting deadlines.
    public init(timeoutClock: any Clock<Duration> = ContinuousClock()) {
        self.timeoutClock = timeoutClock
        nativeWorkerQueue = DispatchQueue(
            label: "com.cmux.terminal-surface-native-lifecycle",
            qos: .utility
        )
    }

    @MainActor
    func reserveHibernationTeardown()
        -> TerminalSurfaceRuntimeTeardownReservation? {
        hibernationAdmission.reserve()
    }

    @MainActor
    func cancelHibernationTeardown(
        _ reservation: TerminalSurfaceRuntimeTeardownReservation
    ) {
        hibernationAdmission.release(reservation)
    }

    /// Reads a bounded screen tail on the native lifecycle worker.
    func readScreenTailVT(
        _ request: TerminalSurfaceRuntimeScreenTailRequest
    ) async -> String? {
        await withCheckedContinuation { continuation in
            queuedOperations.append(
                .screenTail(
                    TerminalSurfaceRuntimeQueuedScreenTail(
                        request: request,
                        continuation: continuation
                    )
                )
            )
            startWorkerIfNeeded()
        }
    }

    /// Queues one main-actor native creation behind all earlier native work.
    ///
    /// Production operations must not suspend while they own the queue. The
    /// async shape exists so concurrency tests can hold a creation operation at
    /// a deterministic boundary without blocking the main actor.
    @discardableResult
    nonisolated func enqueueRuntimeCreation(
        id: UUID,
        reason: String,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) -> TerminalSurfaceRuntimeCreationTicket {
        let completion = TerminalSurfaceRuntimeTeardownCompletion()
        let request = TerminalSurfaceRuntimeCreationRequest(
            id: id,
            reason: reason,
            operation: operation,
            completion: completion
        )
        Task {
            await self.enqueue(.creation(request))
        }
        return TerminalSurfaceRuntimeCreationTicket(completion: completion)
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
        callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?,
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
        hibernationReservation:
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
            freeSurface: freeSurface,
            completion: completion
        )
        Task {
            await self.enqueue(
                .teardown(
                    TerminalSurfaceRuntimeQueuedTeardown(
                        request: request,
                        hibernationReservation:
                            hibernationReservation
                    )
                )
            )
        }
        return ticket
    }

    private func enqueue(_ operation: TerminalSurfaceRuntimeNativeOperation) {
        if case let .teardown(queuedTeardown) = operation {
            pendingReasonsById[queuedTeardown.request.id] =
                queuedTeardown.request.reason
        }
        queuedOperations.append(operation)
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard !isWorkerRunning else { return }
        isWorkerRunning = true
        Task(priority: .utility) {
            await self.drainQueuedOperations()
        }
    }

    private func drainQueuedOperations() async {
        while let operation = nextOperationForWorker() {
            switch operation {
            case let .creation(request):
#if DEBUG
                logDebugEvent(
                    "surface.lifecycle.nativeCreate.begin surface=\(request.id.uuidString.prefix(5)) " +
                    "reason=\(request.reason)"
                )
#endif
                await request.operation()
                await request.completion.finish()
#if DEBUG
                logDebugEvent(
                    "surface.lifecycle.nativeCreate.end surface=\(request.id.uuidString.prefix(5)) " +
                    "reason=\(request.reason)"
                )
#endif
            case let .screenTail(queuedRead):
                let result = await readScreenTailOnNativeWorker(
                    queuedRead.request
                )
                queuedRead.continuation.resume(returning: result)
            case let .teardown(queuedTeardown):
                let request = queuedTeardown.request
                Task {
                    await self.observeTimeout(id: request.id)
                }
                await freeNativeSurfaceOnWorker(request)
                await finishFree(request)
                if let reservation = queuedTeardown.hibernationReservation {
                    await hibernationAdmission.release(reservation)
                }
                complete(id: request.id)
            }
        }
    }

    private func nextOperationForWorker()
        -> TerminalSurfaceRuntimeNativeOperation?
    {
        guard nextQueuedOperationIndex < queuedOperations.count else {
            queuedOperations.removeAll(keepingCapacity: true)
            nextQueuedOperationIndex = 0
            isWorkerRunning = false
            return nil
        }
        let operation = queuedOperations[nextQueuedOperationIndex]
        nextQueuedOperationIndex += 1
        if nextQueuedOperationIndex == queuedOperations.count {
            queuedOperations.removeAll(keepingCapacity: true)
            nextQueuedOperationIndex = 0
        }
        return operation
    }

    private nonisolated func readScreenTailOnNativeWorker(
        _ request: TerminalSurfaceRuntimeScreenTailRequest
    ) async -> String? {
        await withCheckedContinuation { continuation in
            nativeWorkerQueue.async {
                continuation.resume(returning: request.read())
            }
        }
    }

    private nonisolated func freeNativeSurfaceOnWorker(
        _ request: TerminalSurfaceRuntimeTeardownRequest
    ) async {
        await withCheckedContinuation { continuation in
            nativeWorkerQueue.async {
                self.freeNativeSurface(request)
                continuation.resume()
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
            try await timeoutClock.sleep(for: timeout)
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
