public import Foundation
public import GhosttyKit
public import CmuxTerminalCore
#if DEBUG
internal import CMUXDebugLog
#endif

/// Serializes native `ghostty_surface_free` calls off the close/deinit paths.
///
/// Frees run one at a time on a utility worker so re-entrant close/deinit
/// loops cannot form, with a deadline observer that reports (but never
/// blocks on) a stuck native free. The app constructs exactly one instance
/// and injects it through ``TerminalSurfaceRuntimeDependencies``.
public actor TerminalSurfaceRuntimeTeardownCoordinator {
    private let timeout: Duration = .seconds(5)
#if DEBUG
    // Readable at internal scope in DEBUG so the debug-only extension in
    // TerminalSurfaceRuntimeTeardownCoordinator+Debug.swift can report the
    // pending count; private in release builds.
    var pendingReasonsById: [UUID: String] = [:]
#else
    private var pendingReasonsById: [UUID: String] = [:]
#endif
    private var queuedRequests: [TerminalSurfaceRuntimeTeardownRequest] = []
    private var queuedRequestReadIndex = 0
    private var isWorkerRunning = false

    /// Creates the process's teardown coordinator.
    public init() {}

    /// Reads a bounded screen tail away from the main actor and before any
    /// subsequently enqueued native free for the same surface.
    ///
    /// The request performs no suspension while it holds the borrowed pointer;
    /// actor serialization therefore makes the read and a later free mutually
    /// exclusive.
    func readScreenTailVT(_ request: TerminalSurfaceRuntimeScreenTailRequest) -> String? {
        request.read()
    }

    /// Reads plain active-screen evidence on the same serialized native lane as
    /// surface teardown, so the borrowed pointer cannot be freed mid-read.
    func readActiveScreenTailText(_ request: TerminalSurfaceRuntimeVisibleTextRequest) -> String? {
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
    public nonisolated func enqueueRuntimeTeardown(
        id: UUID,
        workspaceId: UUID,
        reason: String,
        surface: ghostty_surface_t,
        callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?,
        freeSurface: @escaping @Sendable (ghostty_surface_t) -> Void = { surface in
            ghostty_surface_free(surface)
        }
    ) {
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

    /// Conditionally frees a hibernating runtime surface on the serialized
    /// native teardown lane.
    ///
    /// The final validation runs after every earlier queued teardown and
    /// immediately before the native free. When validation rejects, the
    /// coordinator neither frees the surface nor releases its callback
    /// userdata, allowing the caller to restore the exact live runtime.
    ///
    /// - Parameter request: The temporary native-runtime ownership transfer,
    ///   including its final validation and free operation.
    /// - Returns: `true` only after the native free and all userdata releases
    ///   have completed; `false` when final validation rejected the request.
    func freeRuntimeSurfaceForAgentHibernation(
        _ request: TerminalSurfaceRuntimeTeardownRequest
    ) async -> TerminalSurfaceRuntimeHibernationTeardownResult {
        await withCheckedContinuation { continuation in
            var request = request
            request.completion = continuation
            enqueue(request)
        }
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
    nonisolated func enqueueRuntimeTeardown(
        id: UUID,
        workspaceId: UUID,
        reason: String,
        surface: ghostty_surface_t,
        callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?,
        manualIOContext: Unmanaged<TerminalManualIOWriteBox>?,
        byteTeeLease: (any TerminalByteTeeLease)?,
        freeSurface: @escaping @Sendable (ghostty_surface_t) -> Void = { surface in
            ghostty_surface_free(surface)
        }
    ) {
        let request = TerminalSurfaceRuntimeTeardownRequest(
            id: id,
            workspaceId: workspaceId,
            reason: reason,
            surface: surface,
            callbackContext: callbackContext,
            manualIOContext: manualIOContext,
            byteTeeLease: byteTeeLease,
            freeSurface: freeSurface
        )
        Task {
            await self.enqueue(request)
        }
    }

    func enqueue(_ request: TerminalSurfaceRuntimeTeardownRequest) {
        pendingReasonsById[request.id] = request.reason
        queuedRequests.append(request)
        if !isWorkerRunning {
            isWorkerRunning = true
            Task.detached(priority: .utility) {
                while let request = await self.nextRequestForWorker() {
                    Task {
                        await self.observeTimeout(id: request.id)
                    }
                    let didFree = await Self.free(request)
                    await self.complete(id: request.id)
                    request.completion?.resume(returning: didFree)
                }
            }
        }
    }

    private func nextRequestForWorker() -> TerminalSurfaceRuntimeTeardownRequest? {
        guard queuedRequestReadIndex < queuedRequests.count else {
            queuedRequests.removeAll(keepingCapacity: true)
            queuedRequestReadIndex = 0
            isWorkerRunning = false
            return nil
        }
        let request = queuedRequests[queuedRequestReadIndex]
        queuedRequestReadIndex += 1
        if queuedRequestReadIndex == queuedRequests.count {
            queuedRequests.removeAll(keepingCapacity: true)
            queuedRequestReadIndex = 0
        }
        return request
    }

    private nonisolated static func free(
        _ request: TerminalSurfaceRuntimeTeardownRequest
    ) async -> TerminalSurfaceRuntimeHibernationTeardownResult {
        if let finalValidation = request.finalValidation {
            let isValid = await finalValidation()
            guard isValid else { return .rejected(finalizer: nil) }
        }
        let finalizer: (@Sendable () -> Void)?
        if let finalTeardownPreparation = request.finalTeardownPreparation {
            guard let preparedFinalizer = finalTeardownPreparation() else {
                return .rejected(finalizer: nil)
            }
            finalizer = preparedFinalizer
        } else {
            finalizer = nil
        }
        if let finalCommit = request.finalCommit, !finalCommit() {
            // Do not run the finalizer here. The surface and callback ownership
            // are still provisional; the main-actor owner must restore all of
            // them and flush queued traffic before relinquishing authority.
            return .rejected(finalizer: finalizer)
        }
#if DEBUG
        logDebugEvent(
            "surface.lifecycle.nativeFree.begin surface=\(request.surfaceToken) " +
            "workspace=\(request.workspaceToken) reason=\(request.reason)"
        )
#endif
        // Keep last-mile authority continuously held from its synchronous
        // preparation through native free. The helper returns only after the
        // finalizer runs, so no `await` can suspend while that authority is
        // active (the app uses it to SIGSTOP/SIGCONT the exact shell generation).
        freeAndFinalize(request, finalizer: finalizer)
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
#if DEBUG
        logDebugEvent(
            "surface.lifecycle.nativeFree.end surface=\(request.surfaceToken) " +
            "workspace=\(request.workspaceToken) reason=\(request.reason)"
        )
#endif
        return .freed
    }

    private nonisolated static func freeAndFinalize(
        _ request: TerminalSurfaceRuntimeTeardownRequest,
        finalizer: (@Sendable () -> Void)?
    ) {
        defer { finalizer?() }
        request.freeSurface(request.surface)
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
