/// Tracks received, pending, and published titles for one Ghostty surface lifetime.
struct GhosttyTitleUpdateSurfaceState {
    var lastSequence: UInt64 = 0
    var lastReceivedTitle: String?
    var lastPublishedTitle: String?
    var pendingUpdate: GhosttyTitleUpdate?
}
