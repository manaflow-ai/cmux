public import Foundation
public import GhosttyKit
public import CmuxTerminalCore

enum TerminalSurfaceRuntimeHibernationTeardownResult: @unchecked Sendable {
    case freed
    case rejected(finalizer: (@Sendable () -> Void)?)
}

/// A native-surface teardown queued on the teardown coordinator.
///
/// The native pointer has been removed from all main-thread owner state
/// before this request is created; this wrapper only transports the one-shot
/// free. It is `@unchecked Sendable` for exactly that reason: the surface
/// pointer, the `Unmanaged` callback contexts, and the byte-tee lease are
/// exclusively owned by an unconditional request from creation until the
/// coordinator consumes them. Agent-hibernation requests temporarily transfer
/// the same resources to the coordinator; failed final validation returns that
/// ownership to the live ``TerminalSurface`` without releasing anything.
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
    let callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?
    let manualIOContext: Unmanaged<TerminalManualIOWriteBox>?
    let byteTeeLease: (any TerminalByteTeeLease)?
    let finalValidation: (@Sendable () async -> Bool)?
    /// Synchronous last-mile preparation run after async validation and
    /// immediately before native free. A successful preparation returns a
    /// one-shot finalizer that the coordinator invokes synchronously after
    /// `freeSurface` and before its next suspension point.
    let finalTeardownPreparation: (@Sendable () -> (@Sendable () -> Void)?)?
    /// Synchronous durable authority commit performed after last-mile
    /// preparation. Rejection returns the prepared finalizer to the main-actor
    /// owner so it can restore native ownership before relinquishing authority.
    let finalCommit: (@Sendable () -> Bool)?
    var completion: CheckedContinuation<TerminalSurfaceRuntimeHibernationTeardownResult, Never>?
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
        manualIOContext: Unmanaged<TerminalManualIOWriteBox>?,
        byteTeeLease: (any TerminalByteTeeLease)?,
        finalValidation: (@Sendable () async -> Bool)? = nil,
        finalTeardownPreparation: (@Sendable () -> (@Sendable () -> Void)?)? = nil,
        finalCommit: (@Sendable () -> Bool)? = nil,
        completion: CheckedContinuation<TerminalSurfaceRuntimeHibernationTeardownResult, Never>? = nil,
        freeSurface: @escaping @Sendable (ghostty_surface_t) -> Void
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.reason = reason
        self.surface = surface
        self.callbackContext = callbackContext
        self.manualIOContext = manualIOContext
        self.byteTeeLease = byteTeeLease
        self.finalValidation = finalValidation
        self.finalTeardownPreparation = finalTeardownPreparation
        self.finalCommit = finalCommit
        self.completion = completion
        self.freeSurface = freeSurface
#if DEBUG
        self.surfaceToken = String(id.uuidString.prefix(5))
        self.workspaceToken = String(workspaceId.uuidString.prefix(5))
#endif
    }
}
