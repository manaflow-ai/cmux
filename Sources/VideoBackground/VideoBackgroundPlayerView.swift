import AppKit

/// A non-interactive view that renders a looping video for the window
/// background and can pause/resume playback and toggle audio on demand.
@MainActor
protocol VideoBackgroundPlayerView: NSView {
    /// Pauses or resumes playback. Safe to call before the player is ready.
    func setPaused(_ paused: Bool)

    /// Silences or unmutes playback. Safe to call before the player is ready.
    func setMuted(_ muted: Bool)
}
