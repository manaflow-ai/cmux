public enum MediaTrackState: Sendable, Hashable {
    case live
    case muted
    /// Terminal. Tracks end with their transport; features re-request.
    case ended
}
