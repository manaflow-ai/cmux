internal import GhosttyKit
internal import CmuxTerminalCore

/// Keeps stale-surface callback userdata alive until a retired output lane is idle.
///
/// A stale wrapper has no native surface that cmux can safely free, but a lane
/// operation that already passed its lifecycle gate may still be using the
/// surface's callback userdata. The box is `@unchecked Sendable` because it is
/// immutable transport for those retained handles; its one-shot release is
/// always performed on the main actor after the lane fence.
final class TerminalSurfaceStaleRuntimeResources: @unchecked Sendable {
    private let callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?
    private let manualIOContext: Unmanaged<TerminalManualIOWriteBox>?
    private let byteTeeLease: (any TerminalByteTeeLease)?

    init(
        callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?,
        manualIOContext: Unmanaged<TerminalManualIOWriteBox>?,
        byteTeeLease: (any TerminalByteTeeLease)?
    ) {
        self.callbackContext = callbackContext
        self.manualIOContext = manualIOContext
        self.byteTeeLease = byteTeeLease
    }

    /// Releases all retained stale-runtime userdata after the lane fence.
    @MainActor
    func release() {
        callbackContext?.release()
        manualIOContext?.release()
        byteTeeLease?.release()
    }
}
