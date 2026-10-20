import Foundation

/// A per-frame media-playback report from the injected media-playback hook.
public struct BrowserMediaPlaybackReport: Sendable {
    /// Stable id for the reporting frame's document, so the native side can
    /// aggregate playback across the main frame and any (cross-origin) iframes.
    public let frameID: String
    /// Whether that frame currently has any actively-playing media.
    public let isPlaying: Bool
    /// Whether that frame currently has an unmuted, non-zero-volume audio source.
    public let isAudible: Bool
    /// Whether that frame has a video in Picture in Picture, playing or paused.
    public let isPictureInPicture: Bool

    public init(
        frameID: String,
        isPlaying: Bool,
        isAudible: Bool,
        isPictureInPicture: Bool = false
    ) {
        self.frameID = frameID
        self.isPlaying = isPlaying
        self.isAudible = isAudible
        self.isPictureInPicture = isPictureInPicture
    }
}
