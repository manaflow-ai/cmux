/// Media playback across a page's frames, folded from the per-frame reports
/// of the injected media-playback hook.
public struct BrowserMediaPlaybackFrames: Equatable, Sendable {
    private var playingFrameIDs: Set<String> = []
    private var audibleFrameIDs: Set<String> = []
    private var pictureInPictureFrameIDs: Set<String> = []

    public init() {}

    /// Whether any frame has actively playing media.
    public var isPlaying: Bool { !playingFrameIDs.isEmpty }
    /// Whether any frame is playing media that is audible.
    public var isAudible: Bool { !audibleFrameIDs.isEmpty }
    /// Whether any frame has a video in Picture in Picture, playing or paused.
    public var isPictureInPictureActive: Bool { !pictureInPictureFrameIDs.isEmpty }

    /// Replaces the reporting frame's state with the report.
    public mutating func apply(_ report: BrowserMediaPlaybackReport) {
        playingFrameIDs.update(report.frameID, isMember: report.isPlaying)
        audibleFrameIDs.update(report.frameID, isMember: report.isPlaying && report.isAudible)
        pictureInPictureFrameIDs.update(report.frameID, isMember: report.isPictureInPicture)
    }
}

private extension Set<String> {
    mutating func update(_ frameID: String, isMember: Bool) {
        if isMember { insert(frameID) } else { remove(frameID) }
    }
}
