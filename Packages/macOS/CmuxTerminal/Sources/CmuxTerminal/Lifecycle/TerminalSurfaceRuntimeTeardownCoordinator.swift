public import Foundation
public import GhosttyKit
public import CmuxTerminalCore
internal import CMUXMobileCore
#if DEBUG
internal import CMUXDebugLog
#endif

final class TerminalNativeSurfaceOperation<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case pending([CheckedContinuation<Value, Never>])
        case resolved(Value)
    }

    private let lock = NSLock()
    private var state: State = .pending([])

    func resolve(_ value: Value) {
        lock.lock()
        guard case .pending(let pendingWaiters) = state else {
            lock.unlock()
            preconditionFailure("native surface operation resolved twice")
        }
        state = .resolved(value)
        lock.unlock()
        for waiter in pendingWaiters {
            waiter.resume(returning: value)
        }
    }

    func value() async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            switch state {
            case .resolved(let result):
                lock.unlock()
                continuation.resume(returning: result)
            case .pending(var waiters):
                waiters.append(continuation)
                state = .pending(waiters)
                lock.unlock()
            }
        }
    }
}

/// Serializes native `ghostty_surface_free` calls off the close/deinit paths.
///
/// Frees run one at a time on a utility worker so re-entrant close/deinit
/// loops cannot form, with a deadline observer that reports (but never
/// blocks on) a stuck native free. The app constructs exactly one instance
/// and injects it through ``TerminalSurfaceRuntimeDependencies``.
public actor TerminalSurfaceRuntimeTeardownCoordinator {
    private let timeout: Duration = .seconds(5)
    /// Every operation that dereferences a native surface pointer runs here.
    /// Enqueueing is synchronous, so a read submitted before owner teardown is
    /// guaranteed to finish before the later free reaches the same FIFO lane.
    private nonisolated let nativeSurfaceQueue = DispatchQueue(
        label: "dev.cmux.terminal.native-surface-lifecycle",
        qos: .utility
    )
    private var pendingReasonsById: [UUID: String] = [:]
    private var queuedRequests: [TerminalSurfaceRuntimeTeardownRequest] = []
    private var isWorkerRunning = false

    /// Creates the process's teardown coordinator.
    public init() {}

    /// Reads a bounded screen tail away from the main actor and before any
    /// subsequently enqueued native free for the same surface.
    ///
    /// Reads and frees share one serial worker. Actor isolation alone is not
    /// sufficient because native free intentionally runs outside this actor.
    nonisolated func enqueueScreenTailVTRead(
        _ request: TerminalSurfaceRuntimeScreenTailRequest
    ) -> TerminalNativeSurfaceOperation<String?> {
        enqueueNativeSurfaceOperation { request.read() }
    }

    /// Captures and decodes one bounded render grid without occupying the main actor.
    nonisolated func enqueueRenderGridRead(
        _ request: TerminalSurfaceRuntimeRenderGridRequest
    ) -> TerminalNativeSurfaceOperation<(frame: MobileTerminalRenderGridFrame, rows: [String])?> {
        enqueueNativeSurfaceOperation { request.read() }
    }

    private nonisolated func enqueueNativeSurfaceOperation<Result: Sendable>(
        _ operation: @escaping @Sendable () -> Result
    ) -> TerminalNativeSurfaceOperation<Result> {
        let pending = TerminalNativeSurfaceOperation<Result>()
        nativeSurfaceQueue.async {
            pending.resolve(operation())
        }
        return pending
    }

    /// Test seam for proving that reads and frees cannot overlap.
    nonisolated func enqueueNativeSurfaceOperationForTesting(
        _ operation: @escaping @Sendable () -> Void
    ) -> TerminalNativeSurfaceOperation<Void> {
        enqueueNativeSurfaceOperation(operation)
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
    ///   - manualIOContext: Retained MANUAL-mode write callback userdata,
    ///     released only after native free has stopped the I/O thread.
    ///   - byteTeeLease: The retained tee callback userdata released only
    ///     after the native free has stopped the PTY read thread.
    ///   - freeSurface: The free operation; defaults to
    ///     `ghostty_surface_free`.
    nonisolated func enqueueRuntimeTeardown(
        id: UUID,
        workspaceId: UUID,
        reason: String,
        surface: ghostty_surface_t,
        callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?,
        manualIOContext: Unmanaged<TerminalManualIOWriteBox>? = nil,
        byteTeeLease: (any TerminalByteTeeLease)? = nil,
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
                    await self.free(request)
                    await self.complete(id: request.id)
                }
            }
        }
    }

    private func nextRequestForWorker() -> TerminalSurfaceRuntimeTeardownRequest? {
        guard !queuedRequests.isEmpty else {
            isWorkerRunning = false
            return nil
        }
        return queuedRequests.removeFirst()
    }

    private nonisolated func free(_ request: TerminalSurfaceRuntimeTeardownRequest) async {
#if DEBUG
        logDebugEvent(
            "surface.lifecycle.nativeFree.begin surface=\(request.surfaceToken) " +
            "workspace=\(request.workspaceToken) reason=\(request.reason)"
        )
#endif
        let operation = enqueueNativeSurfaceOperation {
            request.freeSurface(request.surface)
        }
        await operation.value()
        if request.callbackContext != nil || request.manualIOContext != nil || request.byteTeeLease != nil {
            // The request is the @unchecked Sendable transport for the
            // callback userdata; release through the request so the @Sendable
            // closure never captures either owner directly. Waiting until
            // native free returns guarantees the PTY read callback is gone.
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
