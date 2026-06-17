import Foundation

/// A per-frame media-playback report from the injected media-playback hook.
struct BrowserMediaPlaybackReport: Sendable {
    /// Stable id for the reporting frame's document, so the native side can
    /// aggregate playback across the main frame and any (cross-origin) iframes.
    let frameID: String
    /// Whether that frame currently has any actively-playing media.
    let isPlaying: Bool
    /// Whether that frame currently has any *audible* media (playing, not muted,
    /// non-zero volume). Drives the sidebar audio-activity indicator (#6100),
    /// independent of ``isPlaying`` which also counts muted video for keep-alive.
    let isAudible: Bool
}
