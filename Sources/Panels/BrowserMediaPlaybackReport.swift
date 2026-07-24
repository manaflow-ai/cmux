import Foundation

/// A per-frame media-playback report from the injected media-playback hook.
struct BrowserMediaPlaybackReport: Sendable {
    /// Stable id for the reporting frame's document, so the native side can
    /// aggregate playback across the main frame and any (cross-origin) iframes.
    let frameID: String
    /// Whether that frame currently has any actively-playing media.
    let isPlaying: Bool
    /// Whether that frame currently has an unmuted, non-zero-volume audio source.
    let isAudible: Bool
}
