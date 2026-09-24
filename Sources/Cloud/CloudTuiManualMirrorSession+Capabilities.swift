import Foundation

extension CloudTuiManualMirrorSession {
    /// Never downgrades to an unleased attachment when the peer promises fencing.
    nonisolated static func requiresLeaseToken(capabilities: [String], lease: String?) -> Bool {
        capabilities.contains("view-attachment-lease-v1") && lease?.isEmpty != false
    }

    /// Recognizes capability errors from daemons that predate geometry claims.
    static func isUnsupportedClaimError(_ error: String?) -> Bool {
        guard let error = error?.lowercased() else { return false }
        return error.contains("unknown command")
            || error.contains("unsupported")
            || error.contains("unrecognized command")
    }

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
