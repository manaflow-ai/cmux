import AppKit
import AVFoundation

/// Plays a local video file on an endless loop for the window background via
/// `AVPlayerLayer` — the fallback for sources YouTube cannot serve. Silent
/// unless the controller unmutes it.
@MainActor
final class VideoBackgroundLocalPlayerView: NSView, VideoBackgroundPlayerView {
    private let item: AVPlayerItem
    private let player: AVQueuePlayer
    private let playerLayer: AVPlayerLayer
    private var looper: AVPlayerLooper?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private let onEnded: @MainActor () -> Void
    private let onReady: @MainActor () -> Void
    private let onFailure: @MainActor (String) -> Void
    private let loops: Bool
    private var desiredPaused = false
    private var didReportReadiness = false
    private var didReportFailure = false
    private var pendingPlaybackPosition: TimeInterval

    init(
        fileURL: URL,
        muted: Bool = true,
        volume: Double = 1,
        loops: Bool = true,
        initialPosition: TimeInterval = 0,
        onEnded: @escaping @MainActor () -> Void = {},
        onReady: @escaping @MainActor () -> Void = {},
        onFailure: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        let item = AVPlayerItem(url: fileURL)
        let player = AVQueuePlayer(items: [item])
        player.isMuted = muted
        player.volume = Float(volume.isFinite ? min(max(volume, 0), 1) : 1)
        player.preventsDisplaySleepDuringVideoPlayback = false
        self.item = item
        self.player = player
        self.playerLayer = AVPlayerLayer(player: player)
        self.onEnded = onEnded
        self.onReady = onReady
        self.onFailure = onFailure
        self.loops = loops
        self.pendingPlaybackPosition = initialPosition.isFinite ? max(0, initialPosition) : 0

        super.init(frame: .zero)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)

        if loops {
            looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            // AVPlayerItem end notifications are the native equivalent of the
            // YouTube bridge's `ended` event for queue-managed playback.
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onEnded() }
            }
        }
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor [weak self] in
                self?.handleItemStatus(status)
            }
        }
        player.play()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        statusObservation?.invalidate()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    private func handleItemStatus(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            guard !didReportReadiness else { return }
            didReportReadiness = true
            applyPendingPlaybackPosition()
            onReady()
        case .failed:
            guard !didReportFailure else { return }
            didReportFailure = true
            // Keep the failure category stable and path-free; the controller's
            // DEBUG event log must never expose a user-selected file URL.
            onFailure("local-file-failed")
        default:
            break
        }
    }

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

    func setMuted(_ muted: Bool) {
        player.isMuted = muted
    }

    func setPlaybackPosition(_ seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { return }
        pendingPlaybackPosition = seconds
        guard didReportReadiness else { return }
        seek(to: seconds)
    }

    func setVolume(_ volume: Double) {
        let normalized = volume.isFinite ? min(max(volume, 0), 1) : 1
        player.volume = Float(normalized)
    }

    private func applyPendingPlaybackPosition() {
        guard pendingPlaybackPosition > 0 else { return }
        seek(to: pendingPlaybackPosition)
    }

    private func seek(to seconds: TimeInterval) {
        let duration = item.duration.seconds
        let position: TimeInterval
        if loops, duration.isFinite, duration > 0 {
            position = seconds.truncatingRemainder(dividingBy: duration)
        } else if duration.isFinite, duration > 0 {
            position = min(seconds, duration)
        } else {
            position = seconds
        }
        pendingPlaybackPosition = position
        player.seek(
            to: CMTime(seconds: position, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
}
