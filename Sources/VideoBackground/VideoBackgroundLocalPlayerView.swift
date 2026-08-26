import AppKit
import AVFoundation

/// Plays a local video file on a muted, endless loop for the window
/// background via `AVPlayerLayer` — the fallback for sources YouTube
/// cannot serve.
@MainActor
final class VideoBackgroundLocalPlayerView: NSView, VideoBackgroundPlayerView {
    private let player: AVQueuePlayer
    private let playerLayer: AVPlayerLayer
    private var looper: AVPlayerLooper?
    private var desiredPaused = false

    init(fileURL: URL) {
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        self.player = player
        self.playerLayer = AVPlayerLayer(player: player)

        super.init(frame: .zero)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)

        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: fileURL))
        player.play()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func setPaused(_ paused: Bool) {
        guard desiredPaused != paused else { return }
        desiredPaused = paused
        if paused {
            player.pause()
        } else {
            player.play()
        }
    }
}
