import AppKit

/// A non-interactive view that renders a looping, muted video for the
/// window background and can pause/resume playback on visibility changes.
@MainActor
protocol VideoBackgroundPlayerView: NSView {
    /// Pauses or resumes playback. Safe to call before the player is ready.
    func setPaused(_ paused: Bool)
}
