public import Foundation

/// Pure desired-playback state that turns native changes into embed scripts.
///
/// The WebKit host uses this value model to retain pause, mute, volume, and
/// playhead requests made before the generated page is ready. Keeping the
/// decision logic here lets tests exercise replay and deduplication without
/// constructing a WebKit view or contacting YouTube.
public struct VideoBackgroundPlaybackCommandModel: Sendable, Equatable {
    /// Whether playback should currently be paused.
    public private(set) var isPaused: Bool
    /// Whether playback should currently be muted.
    public private(set) var isMuted: Bool
    /// The desired shared playhead in seconds.
    public private(set) var position: TimeInterval
    /// The desired volume in the `0...1` range.
    public private(set) var volume: Double

    /// Creates desired state for a player that may not be ready yet.
    ///
    /// - Parameters:
    ///   - muted: Initial mute state.
    ///   - initialPosition: Shared playhead; invalid values become zero.
    ///   - volume: Initial volume, clamped to `0...1`.
    public init(
        muted: Bool = true,
        initialPosition: TimeInterval = 0,
        volume: Double = 1
    ) {
        self.isPaused = false
        self.isMuted = muted
        self.position = initialPosition.isFinite ? max(0, initialPosition) : 0
        self.volume = volume.isFinite ? min(max(volume, 0), 1) : 1
    }

    /// Updates pause state and returns the script to evaluate, if it changed.
    public mutating func setPaused(_ paused: Bool) -> String? {
        guard isPaused != paused else { return nil }
        isPaused = paused
        return paused ? VideoBackgroundEmbedPage.pauseScript : VideoBackgroundEmbedPage.resumeScript
    }

    /// Updates mute state and returns the script to evaluate, if it changed.
    public mutating func setMuted(_ muted: Bool) -> String? {
        guard isMuted != muted else { return nil }
        isMuted = muted
        return VideoBackgroundEmbedPage.mutedScript(muted)
    }

    /// Updates the desired playhead and returns a script when the move is
    /// material enough to avoid per-frame seek churn.
    public mutating func setPosition(_ seconds: TimeInterval) -> String? {
        let normalized = seconds.isFinite ? max(0, seconds) : 0
        guard abs(position - normalized) > 0.05 else { return nil }
        position = normalized
        return VideoBackgroundEmbedPage.positionScript(normalized)
    }

    /// Updates volume and returns a script when the change exceeds the
    /// deduplication tolerance.
    public mutating func setVolume(_ nextVolume: Double) -> String? {
        let normalized = nextVolume.isFinite ? min(max(nextVolume, 0), 1) : 1
        guard abs(volume - normalized) > 0.005 else { return nil }
        volume = normalized
        return VideoBackgroundEmbedPage.volumeScript(normalized)
    }

    /// Returns the complete desired state replay for a newly loaded page.
    public func replayCommands() -> [String] {
        var commands = [
            isPaused ? VideoBackgroundEmbedPage.pauseScript : VideoBackgroundEmbedPage.resumeScript,
            VideoBackgroundEmbedPage.mutedScript(isMuted),
            VideoBackgroundEmbedPage.volumeScript(volume),
        ]
        if position > 0 {
            commands.append(VideoBackgroundEmbedPage.positionScript(position))
        }
        return commands
    }
}
