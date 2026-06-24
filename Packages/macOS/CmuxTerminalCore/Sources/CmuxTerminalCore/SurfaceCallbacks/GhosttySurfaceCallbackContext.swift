public import Foundation
public import GhosttyKit

/// The retained userdata handed to libghostty surface callbacks.
///
/// One context is allocated per runtime surface and passed to
/// `ghostty_surface_new` as an `Unmanaged` opaque pointer; callbacks recover
/// it with `takeUnretainedValue()` and use it to find the owning surface
/// model and host view through the ``TerminalSurfaceControlling`` and
/// ``TerminalSurfaceHosting`` seams.
///
/// Isolation: this type is intentionally not `Sendable` and holds no
/// synchronization. Both references are `weak`, the identifiers are immutable,
/// and libghostty may invoke callbacks off the main thread; callbacks read
/// the context, then hop to the main actor before touching the model or view,
/// preserving the legacy contract exactly. The owner releases the context
/// only after the runtime surface has been freed.
public final class GhosttySurfaceCallbackContext {
    /// The host view, used as a fallback identity source when the model
    /// reference has been released.
    public private(set) weak var surfaceHost: (any TerminalSurfaceHosting)?

    /// The surface model that owns the runtime surface.
    public private(set) weak var surfaceController: (any TerminalSurfaceControlling)?

    /// The stable identity of the surface this context was created for.
    public let surfaceId: UUID

    /// Creates the callback userdata for one runtime surface.
    ///
    /// - Parameters:
    ///   - surfaceHost: The view hosting the surface.
    ///   - surfaceController: The surface model owning the runtime surface.
    public init(
        surfaceHost: any TerminalSurfaceHosting,
        surfaceController: any TerminalSurfaceControlling
    ) {
        self.surfaceHost = surfaceHost
        self.surfaceController = surfaceController
        self.surfaceId = surfaceController.surfaceId
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
