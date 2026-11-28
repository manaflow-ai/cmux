internal import CmuxTerminalCore

extension TerminalSurface {
    /// Reclaims clipboard work owned by one retained native callback context.
    @MainActor
    func invalidateRuntimeClipboardRequests(
        in callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?,
        completingNativeRequests: Bool
    ) {
        callbackContext?.takeUnretainedValue()
            .invalidateRuntimeClipboardRequests(
                completingNativeRequests: completingNativeRequests
            )
    }
}
