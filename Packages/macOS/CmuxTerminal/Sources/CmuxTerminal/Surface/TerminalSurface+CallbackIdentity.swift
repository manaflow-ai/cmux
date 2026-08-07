public import CmuxTerminalCore

extension TerminalSurface {
    /// Returns whether `callbackContext` still owns this model's native
    /// runtime callback slot.
    ///
    /// A `TerminalSurface` model can outlive and replace its Ghostty runtime
    /// surface. Comparing the retained per-runtime callback context prevents a
    /// delayed callback from being associated with the replacement pointer.
    @MainActor
    public func isActiveRuntimeCallbackContext(
        _ callbackContext: GhosttySurfaceCallbackContext
    ) -> Bool {
        surfaceCallbackContext?.takeUnretainedValue() === callbackContext
    }
}
