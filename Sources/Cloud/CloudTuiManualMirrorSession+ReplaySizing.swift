import CmuxTerminal

extension CloudTuiManualMirrorSession {
    /// Keep the local pane's last real geometry while a hidden replay briefly
    /// aligns Ghostty to the remote snapshot grid.
    func rememberReplaySizingSampleIfHidden() {
        guard pendingReplaySizingSample == nil,
              surface?.isRendererPortalVisible != true,
              let sample = surface?.rawSizingSample(),
              sample.columns > 1,
              sample.rows > 1 else { return }
        pendingReplaySizingSample = sample
    }

    /// Re-publish the saved local geometry on reveal; the current Ghostty grid
    /// may still describe the remote replay and fail pane-pixel validation.
    @discardableResult
    func applyPendingReplaySizingSampleIfVisible() -> Bool {
        guard surface?.isRendererPortalVisible == true,
              let sample = pendingReplaySizingSample else { return false }
        pendingReplaySizingSample = nil
        apply(size: sample, validatePanePixels: false)
        return true
    }
}
