import Foundation

/// Owns the process-scoped video-background collaborators assembled by the
/// application composition root.
///
/// Main-window views receive this instance explicitly so audio ownership and
/// queue/playhead state are shared across windows without relying on ambient
/// singletons. Tests can construct an independent runtime for each scenario.
@MainActor
final class VideoBackgroundRuntime {
    let audioArbiter: VideoBackgroundAudioArbiter
    let playbackCoordinator: VideoBackgroundPlaybackCoordinator

    init(
        audioArbiter: VideoBackgroundAudioArbiter = VideoBackgroundAudioArbiter(),
        playbackCoordinator: VideoBackgroundPlaybackCoordinator = VideoBackgroundPlaybackCoordinator()
    ) {
        self.audioArbiter = audioArbiter
        self.playbackCoordinator = playbackCoordinator
    }
}
