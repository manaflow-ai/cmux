import AppKit
import AVFoundation
import AVKit

/// The large video viewer over a Chief chat pane (the user, 2026-10-30: "i want to double click
/// it and see it bigger"). The pane dims and blurs under the video; AVKit's floating controls
/// scrub, change the volume and go full screen; Space plays and pauses, the arrow keys step, and
/// Esc or a click on the dim closes it. It stays inside its pane and never covers other panes.
@MainActor
final class HomeVideoViewer: NSView {
    let playerView = AVPlayerView(frame: .zero)
    private let backdrop = NSVisualEffectView(frame: .zero)
    private let dim = NSView(frame: .zero)
    private let closeButton = NSButton(frame: .zero)
    /// The video's pixel size (its aspect fits the pane), nil until known.
    private let videoSize: CGSize?
    /// The viewer closed (Esc, the close button, a click on the dim); the time it stopped at.
    var onClose: (CMTime) -> Void = { _ in }

    init(frame: NSRect, videoSize: CGSize?) {
        self.videoSize = videoSize
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        playerView.videoGravity = .resizeAspect
        playerView.wantsLayer = true
        playerView.layer?.cornerRadius = 10
        playerView.layer?.masksToBounds = true
        playerView.layer?.backgroundColor = NSColor.black.cgColor
        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: CmuxStrings.closeVideoViewer)
        closeButton.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.8)
        closeButton.toolTip = CmuxStrings.closeVideoViewer
        closeButton.setAccessibilityLabel(CmuxStrings.closeVideoViewer)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        for v in [backdrop, dim, playerView, closeButton] { addSubview(v) }
        setAccessibilityRole(.group)
        setAccessibilityLabel(CmuxStrings.viewVideoLarger)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Plays `url` from `time`.
    func play(_ url: URL, from time: CMTime) {
        let player = AVPlayer(url: url)
        if time != .zero { player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) }
        playerView.player = player
        player.play()
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        dim.frame = bounds
        playerView.frame = Self.videoFrame(in: bounds, videoSize: videoSize)
        closeButton.frame = CGRect(x: bounds.maxX - 36, y: bounds.minY + 10, width: 26, height: 26)
    }

    /// The video's frame in a pane of `bounds`: its aspect, as large as fits with a 24 pt margin
    /// (40 pt at the top for the close button), centred.
    nonisolated static func videoFrame(in bounds: CGRect, videoSize: CGSize?) -> CGRect {
        let area = CGRect(x: bounds.minX + 24, y: bounds.minY + 40, width: bounds.width - 48, height: bounds.height - 64)
        guard area.width > 0, area.height > 0 else { return .zero }
        guard let size = videoSize, size.width > 0, size.height > 0 else { return area }
        let scale = min(area.width / size.width, area.height / size.height)
        let w = (size.width * scale).rounded(), h = (size.height * scale).rounded()
        return CGRect(x: (area.midX - w / 2).rounded(), y: (area.midY - h / 2).rounded(), width: w, height: h)
    }

    /// A click outside the video closes the viewer; one on the video is AVKit's (play, scrub).
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !playerView.frame.contains(p) { close() }
    }

    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close(); return }
        super.keyDown(with: event)
    }

    @objc private func closeClicked() { close() }

    func close() {
        guard superview != nil else { return }
        let time = playerView.player?.currentTime() ?? .zero
        playerView.player?.pause()
        playerView.player = nil
        removeFromSuperview()
        onClose(time)
    }
}
