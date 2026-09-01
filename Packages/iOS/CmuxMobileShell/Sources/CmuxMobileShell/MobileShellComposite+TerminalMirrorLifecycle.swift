import CMUXMobileCore
internal import CmuxMobileTerminalKit

extension MobileShellComposite {
    /// Marks every mounted terminal mirror as blank at an intentional teardown
    /// boundary. Surface identifiers can be reused by another Mac or account,
    /// so retaining the old producer metadata would risk skipping hydration.
    func invalidateMountedTerminalMirrors() {
        for surfaceID in terminalByteContinuationsBySurfaceID.keys {
            var mirrorState = terminalMirrorStatesBySurfaceID[surfaceID]
                ?? MobileTerminalMirrorState()
            mirrorState.invalidate()
            terminalMirrorStatesBySurfaceID[surfaceID] = mirrorState
        }
    }

    /// Mark a mounted mirror blank so its next screen-anchored replay hydrates
    /// the local scrollback from the current producer.
    func markTerminalMirrorHydrationNeeded(surfaceID: String) {
        var state = terminalMirrorStatesBySurfaceID[surfaceID]
            ?? MobileTerminalMirrorState()
        state.invalidate()
        terminalMirrorStatesBySurfaceID[surfaceID] = state
    }

    /// Record the producer identity and history baseline of a delivered frame.
    func recordTerminalMirrorFrame(_ frame: MobileTerminalRenderGridFrame) {
        var state = terminalMirrorStatesBySurfaceID[frame.surfaceID]
            ?? MobileTerminalMirrorState()
        state.record(frame)
        terminalMirrorStatesBySurfaceID[frame.surfaceID] = state
    }

    /// Returns whether a retained mirror's provisional zero-row replay failed
    /// its producer-identity and history-freshness checks.
    func terminalMirrorRequiresHydration(
        surfaceID: String,
        frame: MobileTerminalRenderGridFrame
    ) -> Bool {
        terminalMirrorStatesBySurfaceID[surfaceID]?.requiresHydration(for: frame)
            ?? true
    }
}
