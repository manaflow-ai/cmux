import AppKit
import Foundation

/// A non-interactive view that renders a looping video for the window
/// background and can pause/resume playback and toggle audio on demand.
@MainActor
protocol VideoBackgroundPlayerView: NSView {
    /// Pauses or resumes playback. Safe to call before the player is ready.
    func setPaused(_ paused: Bool)

    /// Silences or unmutes playback. Safe to call before the player is ready.
    func setMuted(_ muted: Bool)

    /// Seeks to a shared playhead position in seconds. Safe before readiness;
    /// implementations retain the requested position until the media exists.
    func setPlaybackPosition(_ seconds: TimeInterval)

    /// Sets the playback volume from silent (`0`) to full (`1`).
    func setVolume(_ volume: Double)
}
