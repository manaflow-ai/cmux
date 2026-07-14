public import Foundation
public import GhosttyKit
internal import OSLog

struct TerminalRendererProfilingStateSnapshot: Equatable, Sendable {
    let visible: Bool
    let focused: Bool
}

/// Lock-backed content-free renderer state shared by the UI and renderer
/// threads. Reads wait for the tiny UI write critical section instead of
/// dropping a structural renderer event from the trace.
final class TerminalRendererProfilingStateStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TerminalRendererProfilingStateSnapshot

    init(visible: Bool = true, focused: Bool = false) {
        self.value = TerminalRendererProfilingStateSnapshot(
            visible: visible,
            focused: focused
        )
    }

    func update(visible: Bool, focused: Bool) {
        lock.lock()
        value = TerminalRendererProfilingStateSnapshot(
            visible: visible,
            focused: focused
        )
        lock.unlock()
    }

    @inline(__always)
    func snapshot() -> TerminalRendererProfilingStateSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// The retained userdata handed to libghostty surface callbacks.
///
/// One context is allocated per runtime surface and passed to
/// `ghostty_surface_new` as an `Unmanaged` opaque pointer; callbacks recover
/// it with `takeUnretainedValue()` and use it to find the owning surface
/// model and host view through the ``TerminalSurfaceControlling`` and
/// ``TerminalSurfaceHosting`` seams.
///
/// Isolation: this type is intentionally not `Sendable`. Both owner references
/// are `weak`; renderer callbacks use only immutable identity plus the tiny
/// profiling snapshot guarded below, without dereferencing either owner or
/// hopping to the main actor. The owner releases the context only after the
/// runtime surface has been freed.
public final class GhosttySurfaceCallbackContext {
    private let rendererState = TerminalRendererProfilingStateStore()
    private let rendererEventSignposts = TerminalRendererProfilingSignposts()
    nonisolated(unsafe) private var rendererEventPairing = TerminalRendererEventPairing()
    nonisolated(unsafe) private var rendererUpdateState: OSSignpostIntervalState?
    nonisolated(unsafe) private var rendererDrawState: OSSignpostIntervalState?
    /// The host view, used as a fallback identity source when the model
    /// reference has been released.
    public private(set) weak var surfaceHost: (any TerminalSurfaceHosting)?

    /// The surface model that owns the runtime surface.
    public private(set) weak var surfaceController: (any TerminalSurfaceControlling)?

    /// The stable identity of the surface this context was created for.
    public let surfaceId: UUID

    /// Stable, opaque renderer trace identity captured before any runtime recreation.
    public let rendererProfilingIdentity: TerminalRendererProfilingIdentity

    /// Whether the process requested renderer profiling through the existing environment gate.
    public var rendererEventProfilingRequested: Bool { rendererEventSignposts.collectionRequested }

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
        self.rendererProfilingIdentity = TerminalRendererProfilingIdentity(
            workspaceId: surfaceController.owningTabId,
            surfaceId: surfaceController.surfaceId
        )
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

    /// Returns whether delayed work still belongs to this context's original
    /// controller, host attachment, and libghostty runtime surface.
    public func isCurrentOrigin(runtimeSurface: ghostty_surface_t?) -> Bool {
        guard let runtimeSurface,
              let surfaceController,
              surfaceController.runtimeSurfacePointer == runtimeSurface,
              let attachedController = surfaceHost?.attachedSurfaceController else {
            return false
        }
        return (attachedController as AnyObject) === (surfaceController as AnyObject)
    }

    /// Publishes content-free UI state for the renderer callback.
    public func updateRendererProfilingState(visible: Bool, focused: Bool) {
        guard rendererEventSignposts.collectionRequested else { return }
        rendererState.update(visible: visible, focused: focused)
    }

    /// Records an exact Ghostty renderer event synchronously on its calling renderer thread.
    @inline(__always)
    public func recordRendererEvent(_ event: ghostty_renderer_event_e) {
        guard rendererEventSignposts.isEnabled,
              let event = TerminalRendererProfilingEvent(event) else { return }
        let state = rendererState.snapshot()

        guard let action = rendererEventPairing.consume(event) else { return }
        let metadata = TerminalRendererEventProfilingMetadata(
            identity: rendererProfilingIdentity,
            visible: state.visible,
            focused: state.focused,
            event: event
        )
        switch action {
        case .begin(.updateFrame):
            rendererUpdateState = rendererEventSignposts.beginRendererEvent(metadata)
        case .end(.updateFrame):
            rendererEventSignposts.endRendererEvent(rendererUpdateState, metadata)
            rendererUpdateState = nil
        case .begin(.drawFrame):
            rendererDrawState = rendererEventSignposts.beginRendererEvent(metadata)
        case .end(.drawFrame):
            rendererEventSignposts.endRendererEvent(rendererDrawState, metadata)
            rendererDrawState = nil
        }
    }
}
