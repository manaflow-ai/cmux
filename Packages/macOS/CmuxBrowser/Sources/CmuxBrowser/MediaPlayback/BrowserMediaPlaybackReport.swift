import Foundation

/// A per-frame media-playback report from the injected media-playback hook.
public struct BrowserMediaPlaybackReport: Equatable, Sendable {
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

    /// The hook's report object (`{ frameID, playing, audible, pip }`), or
    /// `nil` when it lacks the frame id or the playing state.
    public init?(body: Any?) {
        guard let body = body as? [String: Any],
              let frameID = body["frameID"] as? String,
              let playing = body["playing"] as? Bool else { return nil }
        self.init(
            frameID: frameID,
            isPlaying: playing,
            isAudible: body["audible"] as? Bool ?? false,
            isPictureInPicture: body["pip"] as? Bool ?? false
        )
    }

    /// The same report as JSON text (Chromium's binding payload).
    public init?(json: String) {
        guard let data = json.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) else { return nil }
        self.init(body: body)
    }
}
