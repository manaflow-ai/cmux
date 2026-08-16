public import Foundation
public import GhosttyKit
public import CmuxTerminalCore

/// A one-shot native-surface free queued on the teardown coordinator.
///
/// The native pointer has been removed from all main-thread owner state
/// before this request is created; this wrapper only transports the one-shot
/// free. It is `@unchecked Sendable` for exactly that reason: the surface
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
    /// The `runtimeSurfaceGeneration` that was current while `surface` was
    /// installed, captured by the caller before nil-ing it out. Identifies
    /// which native-runtime lifetime this request is ending — see
    /// `RuntimeSurfaceLifetimeID`.
    let runtimeSurfaceGeneration: UInt64
    let callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?
    let manualIOContext: Unmanaged<TerminalManualIOWriteBox>?
    let byteTeeLease: (any TerminalByteTeeLease)?
    let freeSurface: @Sendable (ghostty_surface_t) -> Void
    /// (C) ExternalHover diagnostics — design v4 §3.4's "clear/teardown"
    /// trigger: the final, destructive drain of any diagnostic entries
    /// still sitting in the ring, called by `admitTeardown` BEFORE
    /// `freeSurface` (never after — a getter call on a freed surface is
    /// exactly what the teardown coordinator's lease discipline exists to
    /// prevent). Takes `lifetimeID` (review B5) so the real
    /// implementation can linearize its dropped-count reporting against
    /// the SAME per-lifetime baseline `ExternalHoverWorkService` uses,
    /// and disambiguate its log lines by surface even without a numeric
    /// `surfaceSerial` in scope. Defaults to the real production
    /// drain+log implementation; tests inject a spy to assert
    /// ordering/liveness without a real Ghostty surface.
    let drainDiagnostics: @Sendable (ghostty_surface_t, RuntimeSurfaceLifetimeID) -> Void
    let completion: TerminalSurfaceRuntimeTeardownCompletion
#if DEBUG
    let surfaceToken: String
    let workspaceToken: String
#endif

    var lifetimeID: RuntimeSurfaceLifetimeID {
        .init(surfaceID: id, runtimeSurfaceGeneration: runtimeSurfaceGeneration)
    }

    init(
        id: UUID,
        workspaceId: UUID,
        reason: String,
        surface: ghostty_surface_t,
        runtimeSurfaceGeneration: UInt64,
        callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?,
        manualIOContext: Unmanaged<TerminalManualIOWriteBox>?,
        byteTeeLease: (any TerminalByteTeeLease)?,
        freeSurface: @escaping @Sendable (ghostty_surface_t) -> Void,
        drainDiagnostics: @escaping @Sendable (ghostty_surface_t, RuntimeSurfaceLifetimeID) -> Void,
        completion: TerminalSurfaceRuntimeTeardownCompletion
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.reason = reason
        self.surface = surface
        self.runtimeSurfaceGeneration = runtimeSurfaceGeneration
        self.callbackContext = callbackContext
        self.manualIOContext = manualIOContext
        self.byteTeeLease = byteTeeLease
        self.freeSurface = freeSurface
        self.drainDiagnostics = drainDiagnostics
        self.completion = completion
#if DEBUG
        self.surfaceToken = String(id.uuidString.prefix(5))
        self.workspaceToken = String(workspaceId.uuidString.prefix(5))
#endif
    }
}
