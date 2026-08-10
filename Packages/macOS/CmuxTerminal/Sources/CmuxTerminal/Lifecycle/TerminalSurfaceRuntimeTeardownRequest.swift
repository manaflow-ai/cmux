internal import Foundation
internal import GhosttyKit
internal import CmuxTerminalCore

/// A one-shot native-surface teardown queued on the teardown coordinator.
///
/// The native pointer has been removed from all main-thread owner state
/// before this request is created; this wrapper only transports the one-shot
/// teardown. It is `@unchecked Sendable` for exactly that reason: the surface
/// pointer, the `Unmanaged` callback contexts, and the byte-tee lease are
/// exclusively owned by the request from creation until the coordinator
/// consumes them.
///
/// The transported callback userdata (`callbackContext`, `manualIOContext`,
/// `byteTeeLease`) is released only after `freeSurface` returns: the native
/// free joins ghostty's IO threads (the io-reader thread that fires the PTY
/// tee callback and the io thread that fires the MANUAL-mode `io_write_cb`),
/// so a release ordered after the free can never race an in-flight callback.
struct TerminalSurfaceRuntimeTeardownRequest: @unchecked Sendable {
    let id: UUID
    let workspaceId: UUID
    let reason: String
    let surface: ghostty_surface_t
    let nativeAccessGate: TerminalSurfaceRuntimeNativeAccessGate
    let callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?
    let manualIOContext: Unmanaged<TerminalManualIOWriteBox>?
    let byteTeeLease: (any TerminalByteTeeLease)?
    let nativeTeardown: TerminalSurfaceRuntimeNativeTeardown
    let completion: TerminalSurfaceRuntimeTeardownCompletion
#if DEBUG
    let surfaceToken: String
    let workspaceToken: String
#endif

    init(
        id: UUID,
        workspaceId: UUID,
        reason: String,
        surface: ghostty_surface_t,
        nativeAccessGate: TerminalSurfaceRuntimeNativeAccessGate,
        callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?,
        manualIOContext: Unmanaged<TerminalManualIOWriteBox>?,
        byteTeeLease: (any TerminalByteTeeLease)?,
        nativeTeardown: TerminalSurfaceRuntimeNativeTeardown,
        completion: TerminalSurfaceRuntimeTeardownCompletion
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.reason = reason
        self.surface = surface
        self.nativeAccessGate = nativeAccessGate
        self.callbackContext = callbackContext
        self.manualIOContext = manualIOContext
        self.byteTeeLease = byteTeeLease
        self.nativeTeardown = nativeTeardown
        self.completion = completion
#if DEBUG
        self.surfaceToken = String(id.uuidString.prefix(5))
        self.workspaceToken = String(workspaceId.uuidString.prefix(5))
#endif
    }
}
