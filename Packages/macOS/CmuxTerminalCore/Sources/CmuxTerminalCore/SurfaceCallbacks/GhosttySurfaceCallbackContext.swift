public import Foundation
public import GhosttyKit
internal import CmuxFoundation

/// The retained userdata handed to libghostty surface callbacks.
///
/// One context is allocated per runtime surface and passed to
/// `ghostty_surface_new` as an `Unmanaged` opaque pointer; callbacks recover
/// it with `takeUnretainedValue()` and use it to find the owning surface
/// model and host view through the ``TerminalSurfaceControlling`` and
/// ``TerminalSurfaceHosting`` seams.
///
/// Isolation: this type is intentionally not `Sendable`. Both references are
/// `weak`, identifiers and handlers are immutable, and the one cross-thread
/// repair bit uses a lock-free atomic gate. Libghostty callbacks read only that
/// state, then the handler hops to the main actor before touching the model or
/// view. The owner releases the context only after the runtime surface has been
/// freed.
public final class GhosttySurfaceCallbackContext {
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

    /// Creates the callback userdata for one runtime surface.
    ///
    /// - Parameters:
    ///   - surfaceHost: The view hosting the surface.
    ///   - surfaceController: The surface model owning the runtime surface.
    ///   - rendererMailboxDidDrain: Called with only the stable surface id after
    ///     an armed repair observes renderer activity following a mailbox drain.
    public init(
        surfaceHost: any TerminalSurfaceHosting,
        surfaceController: any TerminalSurfaceControlling,
        rendererMailboxDidDrain: @escaping @Sendable (UUID) -> Void = { _ in }
    ) {
        self.surfaceHost = surfaceHost
        self.surfaceController = surfaceController
        self.surfaceId = surfaceController.surfaceId
        self.rendererMailboxDidDrainHandler = rendererMailboxDidDrain
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
