/// Tracks received, pending, and published titles for one Ghostty surface lifetime.
struct GhosttyTitleUpdateSurfaceState {
    var lastReceivedUpdate: GhosttyTitleUpdate?
    var lastPublishedUpdate: GhosttyTitleUpdate?
    var pendingUpdate: GhosttyTitleUpdate?
}
