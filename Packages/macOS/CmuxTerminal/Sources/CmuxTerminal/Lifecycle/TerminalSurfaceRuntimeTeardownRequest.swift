public import Foundation
public import GhosttyKit
public import CmuxTerminalCore

/// A one-shot native-surface free queued on the teardown coordinator.
///
/// The native pointer has been removed from all main-thread owner state
/// before this request is created; this wrapper only transports the one-shot
/// free. It is `@unchecked Sendable` for exactly that reason: the surface
/// pointer and `Unmanaged` callback context are exclusively owned by the
/// request from creation until the coordinator consumes them.
struct TerminalSurfaceRuntimeTeardownRequest: @unchecked Sendable {
    let id: UUID
    let workspaceId: UUID
    let reason: String
    let surface: ghostty_surface_t
    let callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?
    let freeSurface: @Sendable (ghostty_surface_t) -> Void
#if DEBUG
    let surfaceToken: String
    let workspaceToken: String
#endif

    init(
        id: UUID,
        workspaceId: UUID,
        reason: String,
        surface: ghostty_surface_t,
        callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?,
        freeSurface: @escaping @Sendable (ghostty_surface_t) -> Void
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.reason = reason
        self.surface = surface
        self.callbackContext = callbackContext
        self.freeSurface = freeSurface
#if DEBUG
        self.surfaceToken = String(id.uuidString.prefix(5))
        self.workspaceToken = String(workspaceId.uuidString.prefix(5))
#endif
    }
}
