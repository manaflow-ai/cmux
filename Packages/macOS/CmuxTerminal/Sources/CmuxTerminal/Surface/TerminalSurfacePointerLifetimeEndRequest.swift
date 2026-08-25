import Foundation

/// Transports pointer-lifetime cleanup from nonisolated ``deinit`` to the main
/// actor without retaining the surface model itself.
///
/// SAFETY: The view reference is owned by this request until the main-actor
/// closure runs; the request only invokes the view's main-actor lifecycle seam.
struct TerminalSurfacePointerLifetimeEndRequest: @unchecked Sendable {
    let view: any TerminalSurfaceNativeViewing
    let runtimeLifetimeId: UUID

    @MainActor
    func end() {
        view.runtimeSurfaceDidEnd(runtimeLifetimeId: runtimeLifetimeId)
    }
}
