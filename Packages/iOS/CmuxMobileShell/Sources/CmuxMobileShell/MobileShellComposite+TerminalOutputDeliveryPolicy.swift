import CMUXMobileCore
import Foundation

extension MobileShellComposite {
    /// Unclassified output cannot prove that it is a safe primary-screen
    /// delta, so verified render-grid mode keeps it behind replay.
    func requiresVerifiedReplayForUnclassifiedDelivery(surfaceID: String) -> Bool {
        // A locally served surface's bytes are the terminal itself, not an
        // echo of Mac-ordered state. There is no Mac replay to verify them
        // against, so gating them on the foreground Mac's transport would
        // freeze the surface (reject, replay, reject again) whenever a
        // render-grid Mac holds the session.
        guard !terminalIsServedLocally(surfaceID: surfaceID) else { return false }
        return terminalOutputTransport == .renderGrid
            && supportedHostCapabilities.contains(Self.terminalVerifiedReplayCapability)
    }

    /// Whether a chunk must apply through the verified freeze/replay/verify/
    /// reveal pipeline. Full render-grid replacements and alternate-screen
    /// deltas use this path because they establish or patch a baseline that
    /// cannot be recovered from primary-screen scrollback. Screen-anchored
    /// primary deltas may use the direct queue when that capability is active,
    /// so sustained output does not wait on a GPU fence.
    func requiresVerifiedReplayApplication(
        for frame: MobileTerminalRenderGridFrame
    ) -> Bool {
        guard terminalOutputTransport == .renderGrid,
              supportedHostCapabilities.contains(Self.terminalVerifiedReplayCapability) else {
            return false
        }
        guard !frame.full,
              usesScreenAnchoredRenderGrid,
              frame.anchor == .screen,
              frame.activeScreen == .primary else { return true }
        // The direct fallback is safe only when this delta still links to the
        // delivered grid. A rejected resize, stale base, or missing baseline
        // must remain behind verified replay instead of bypassing that gate.
        guard MobileTerminalRenderGridRevisionContinuity.admits(
            frame,
            delivered: terminalRenderGridRevisionContinuityBySurfaceID[frame.surfaceID]
        ) else { return true }
        if frame.isReplaceableViewportPatchForMobileDelivery {
            guard let delivered = terminalRenderGridRevisionContinuityBySurfaceID[frame.surfaceID],
                  let deliveredColumns = delivered.columns,
                  let deliveredRows = delivered.rows,
                  deliveredColumns == frame.columns,
                  deliveredRows == frame.rows else { return true }
        }
        return false
    }

}
