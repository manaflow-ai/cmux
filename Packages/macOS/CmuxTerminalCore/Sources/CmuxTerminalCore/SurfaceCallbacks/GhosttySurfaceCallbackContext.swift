public import Foundation
public import GhosttyKit
internal import CmuxFoundation
internal import os

/// The retained userdata handed to libghostty surface callbacks.
///
/// One context is allocated per runtime surface and passed to
/// `ghostty_surface_new` as an `Unmanaged` opaque pointer; callbacks recover
/// it with `takeUnretainedValue()` and use it to find the owning surface
/// model and host view through the ``TerminalSurfaceControlling`` and
/// ``TerminalSurfaceHosting`` seams.
///
/// Isolation: this type is intentionally not `Sendable`. Both references are
/// `weak`, identifiers and renderer handlers are immutable, and the renderer
/// repair bit uses a lock-free atomic gate. The short unfair-lock critical
/// section is the synchronous C-callback carve-out that transfers accepted
/// clipboard requests to main-actor lifecycle ownership without blocking on an
/// actor hop. The owner releases the context only after the runtime surface has
/// been freed.
public final class GhosttySurfaceCallbackContext {
    private typealias RuntimeClipboardInvalidation =
        @MainActor @Sendable (_ wasAdmitted: Bool, _ completesNativeRequest: Bool) -> Void

    private struct RuntimeClipboardRequest: Sendable {
        var task: Task<Void, Never>?
        var isCommitted = false
        var wasAdmitted = false
        let onInvalidation: RuntimeClipboardInvalidation
    }

    private struct RuntimeClipboardState: Sendable {
        var acceptsRequests = true
        var surfaceAddress: UInt?
        var requests: [UInt: RuntimeClipboardRequest] = [:]
    }

    /// The host view, used as a fallback identity source when the model
    /// reference has been released.
    public private(set) weak var surfaceHost: (any TerminalSurfaceHosting)?

    /// The surface model that owns the runtime surface.
    public private(set) weak var surfaceController: (any TerminalSurfaceControlling)?

    /// The stable identity of the surface this context was created for.
    public let surfaceId: UUID

    /// Runs after renderer activity consumes an armed presentation repair.
    private let rendererMailboxDidDrainHandler: @Sendable (UUID) -> Void

    /// Lock-free so the unarmed renderer callback path neither allocates nor locks.
    private let rendererPresentationRepairArmed = AtomicBooleanGate(false)

    /// Synchronously bridges libghostty callback acceptance to runtime teardown.
    private let runtimeClipboardState = OSAllocatedUnfairLock(
        initialState: RuntimeClipboardState()
    )

    /// Bounds native request state before any task or input reservation exists.
    private let maximumRuntimeClipboardRequests: Int

    /// Creates the callback userdata for one runtime surface.
    ///
    /// - Parameters:
    ///   - surfaceHost: The view hosting the surface.
    ///   - surfaceController: The surface model owning the runtime surface.
    ///   - rendererMailboxDidDrain: Called with only the stable surface id after
    ///     an armed repair observes renderer activity following a mailbox drain.
    ///   - maximumRuntimeClipboardRequests: Maximum simultaneous native
    ///     clipboard requests accepted for this surface.
    public init(
        surfaceHost: any TerminalSurfaceHosting,
        surfaceController: any TerminalSurfaceControlling,
        rendererMailboxDidDrain: @escaping @Sendable (UUID) -> Void = { _ in },
        maximumRuntimeClipboardRequests: Int = 32
    ) {
        self.surfaceHost = surfaceHost
        self.surfaceController = surfaceController
        self.surfaceId = surfaceController.surfaceId
        self.rendererMailboxDidDrainHandler = rendererMailboxDidDrain
        self.maximumRuntimeClipboardRequests = max(
            0,
            maximumRuntimeClipboardRequests
        )
    }

    /// Arms one presentation repair for the next renderer mailbox-drain signal.
    public func armRendererPresentationRepair() {
        rendererPresentationRepairArmed.storeRelease(true)
    }

    /// Cancels an armed repair after the native renderer enqueue succeeds.
    public func cancelRendererPresentationRepair() {
        rendererPresentationRepairArmed.storeRelease(false)
    }

    /// Consumes at most one armed repair after the renderer drains its mailbox.
    ///
    /// - Returns: Whether this drain scheduled the armed repair.
    @discardableResult
    public func rendererMailboxDidDrain() -> Bool {
        guard rendererPresentationRepairArmed.compareExchange(
            expected: true,
            desired: false
        ) else { return false }
        rendererMailboxDidDrainHandler(surfaceId)
        return true
    }

    /// Binds this callback context to the native surface that owns its userdata.
    ///
    /// The address never follows the host view to a replacement surface. A
    /// callback that arrives before binding or after invalidation fails closed.
    ///
    /// - Parameter surface: The native surface created with this context.
    /// - Returns: Whether the live context accepted this surface identity.
    @discardableResult
    public func bindRuntimeClipboardSurface(_ surface: ghostty_surface_t) -> Bool {
        let address = UInt(bitPattern: surface)
        return runtimeClipboardState.withLock { state in
            guard state.acceptsRequests,
                  state.surfaceAddress == nil || state.surfaceAddress == address else {
                return false
            }
            state.surfaceAddress = address
            return true
        }
    }

    /// The immutable native surface address bound to this callback context.
    public var runtimeClipboardSurfaceAddress: UInt? {
        runtimeClipboardState.withLock { state in
            state.surfaceAddress
        }
    }

    /// Registers one native clipboard request before its callback returns.
    ///
    /// Registration is synchronous because returning `true` from libghostty's
    /// callback transfers responsibility for completing the request to cmux.
    ///
    /// - Parameters:
    ///   - id: The bit pattern of libghostty's opaque request state.
    ///   - reserveAdmission: Attempts a bounded synchronous reservation under
    ///     the same lock as the request so teardown cannot overtake it.
    ///   - onInvalidation: Main-actor cleanup that completes or abandons the
    ///     native request and releases the matching input reservation.
    /// - Returns: Whether this live runtime context accepted the request.
    public func registerRuntimeClipboardRequest(
        id: UInt,
        reserveAdmission: @Sendable () -> Bool = { true },
        onInvalidation: @escaping @MainActor @Sendable (
            _ wasAdmitted: Bool,
            _ completesNativeRequest: Bool
        ) -> Void
    ) -> Bool {
        let requestLimit = maximumRuntimeClipboardRequests
        return runtimeClipboardState.withLock { state in
            guard state.acceptsRequests,
                  state.surfaceAddress != nil,
                  state.requests.count < requestLimit,
                  state.requests[id] == nil else {
                return false
            }
            guard reserveAdmission() else { return false }
            state.requests[id] = RuntimeClipboardRequest(
                task: nil,
                onInvalidation: onInvalidation
            )
            return true
        }
    }

    /// Commits callback ownership immediately before it returns `true`.
    ///
    /// A teardown racing earlier registration invalidates the reservation
    /// without completing native state, allowing libghostty to reclaim the
    /// request when the callback returns `false`.
    ///
    /// - Parameter id: The registered native request identifier.
    /// - Returns: Whether cmux now owns the native request completion.
    @discardableResult
    public func commitRuntimeClipboardRequest(_ id: UInt) -> Bool {
        runtimeClipboardState.withLock { state in
            guard state.acceptsRequests,
                  var request = state.requests[id] else {
                return false
            }
            request.isCommitted = true
            state.requests[id] = request
            return true
        }
    }

    /// Attaches the cancellable preparation task to an accepted request.
    ///
    /// If teardown already consumed the request, the task is cancelled before
    /// this method returns.
    ///
    /// - Parameters:
    ///   - task: The preparation task owned by this runtime request.
    ///   - requestID: The registered native request identifier.
    /// - Returns: Whether the task was attached to a live request.
    @discardableResult
    public func attachRuntimeClipboardTask(
        _ task: Task<Void, Never>,
        requestID: UInt
    ) -> Bool {
        let attached = runtimeClipboardState.withLock { state in
            guard var request = state.requests[requestID] else { return false }
            request.task = task
            state.requests[requestID] = request
            return true
        }
        if !attached {
            task.cancel()
        }
        return attached
    }

    /// Marks that the view's reserved input admission became an active request.
    ///
    /// - Parameter id: The registered native request identifier.
    /// - Returns: Whether the request still belongs to this live runtime.
    @MainActor
    @discardableResult
    public func markRuntimeClipboardRequestAdmitted(_ id: UInt) -> Bool {
        runtimeClipboardState.withLock { state in
            guard var request = state.requests[id],
                  request.isCommitted else {
                return false
            }
            request.wasAdmitted = true
            state.requests[id] = request
            return true
        }
    }

    /// Consumes a normally completed request so teardown cannot complete it again.
    ///
    /// - Parameter id: The registered native request identifier.
    /// - Returns: Whether this call claimed the request's one completion.
    @MainActor
    @discardableResult
    public func completeRuntimeClipboardRequest(_ id: UInt) -> Bool {
        runtimeClipboardState.withLock { state in
            guard state.requests[id]?.isCommitted == true else { return false }
            _ = state.requests.removeValue(forKey: id)
            return true
        }
    }

    /// Cancels and reclaims one clipboard request that cannot continue.
    ///
    /// - Parameters:
    ///   - id: The registered native request identifier.
    ///   - completingNativeRequest: Whether invalidation should complete the
    ///     accepted libghostty request.
    @MainActor
    public func invalidateRuntimeClipboardRequest(
        _ id: UInt,
        completingNativeRequest: Bool
    ) {
        Self.invalidateRuntimeClipboardRequest(
            id,
            completingNativeRequest: completingNativeRequest,
            in: runtimeClipboardState
        )
    }

    /// Creates a main-actor invalidation capability for one request.
    ///
    /// The returned closure captures only the Sendable, lock-protected request
    /// registry rather than sending this callback context across isolation
    /// domains.
    public func makeRuntimeClipboardInvalidationHandler(
        for id: UInt,
        completingNativeRequest: Bool
    ) -> @MainActor @Sendable () -> Void {
        let runtimeClipboardState = runtimeClipboardState
        return {
            Self.invalidateRuntimeClipboardRequest(
                id,
                completingNativeRequest: completingNativeRequest,
                in: runtimeClipboardState
            )
        }
    }

    @MainActor
    private static func invalidateRuntimeClipboardRequest(
        _ id: UInt,
        completingNativeRequest: Bool,
        in runtimeClipboardState: OSAllocatedUnfairLock<RuntimeClipboardState>
    ) {
        let request = runtimeClipboardState.withLock { state in
            state.requests.removeValue(forKey: id)
        }
        guard let request else { return }
        request.task?.cancel()
        request.onInvalidation(
            request.wasAdmitted,
            completingNativeRequest && request.isCommitted
        )
    }

    /// Cancels and reclaims every clipboard request owned by this runtime.
    ///
    /// Call this on the main actor before freeing or replacing the native
    /// surface. In the out-of-band stale-pointer case, pass `false` so cleanup
    /// does not dereference a native surface that is already gone.
    ///
    /// - Parameter completingNativeRequests: Whether each invalidation should
    ///   complete its accepted libghostty request before native free.
    @MainActor
    public func invalidateRuntimeClipboardRequests(
        completingNativeRequests: Bool
    ) {
        let requests = runtimeClipboardState.withLock { state in
            state.acceptsRequests = false
            let requests = Array(state.requests.values)
            state.requests.removeAll(keepingCapacity: false)
            return requests
        }
        for request in requests {
            request.task?.cancel()
            request.onInvalidation(
                request.wasAdmitted,
                completingNativeRequests && request.isCommitted
            )
        }
    }

    /// The owning workspace tab, read from the model first and the view as a
    /// fallback.
    public var tabId: UUID? {
        surfaceController?.owningTabId ?? surfaceHost?.hostedTabId
    }

    /// The live runtime surface pointer, read from the model first and the
    /// view's currently attached model as a fallback.
    public var runtimeSurface: ghostty_surface_t? {
        surfaceController?.runtimeSurfacePointer
            ?? surfaceHost?.attachedSurfaceController?.runtimeSurfacePointer
    }
}
