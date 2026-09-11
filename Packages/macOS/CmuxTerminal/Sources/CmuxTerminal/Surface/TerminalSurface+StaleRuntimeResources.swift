import Foundation

extension TerminalSurface {
    /// Retires callback userdata and output state when the native surface is
    /// absent or cannot be freed safely. A failed or out-of-band realization
    /// can still leave these handles alive, so they follow the same lane fence
    /// as a native free before their retained references are released.
    @MainActor
    func retireRuntimeResourcesWithoutSurface(reason: String) {
        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil
        let manualIOContext = self.manualIOContext
        self.manualIOContext = nil
        let teeLease = mobileByteTeeLease
        mobileByteTeeLease = nil
        invalidateRuntimeClipboardRequests(
            in: callbackContext,
            completingNativeRequests: false
        )
        let retiredRemoteOutputLane = retireRemoteOutputLane()
        byteTee.dropSurface(surfaceID: id)
        let staleRuntimeResources = TerminalSurfaceStaleRuntimeResources(
            callbackContext: callbackContext,
            manualIOContext: manualIOContext,
            byteTeeLease: teeLease
        )
        staleRuntimeResourceReleaseTicket = runtimeTeardown.enqueueRuntimeTeardownFence(
            id: UUID(),
            workspaceId: tabId,
            reason: reason,
            fence: {
                await retiredRemoteOutputLane.drain()
            },
            onCompletion: {
                staleRuntimeResources.release()
            }
        )
    }

}
