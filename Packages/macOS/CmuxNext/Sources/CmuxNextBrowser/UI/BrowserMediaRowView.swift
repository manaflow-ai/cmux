public import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// One tab's card in the media hub menu (Edge's Now Playing, cx-6qwm.2):
/// artwork, title, artist and site, then Previous, Play or Pause, Next and
/// Mute. A control runs `onCommand` and keeps the menu open (the row flips
/// its own Play/Pause and Mute at once; the page's next report confirms
/// them); a click elsewhere on the card runs `onReveal` and closes the
/// menu. Previous and Next are off when the page handles no such action.
public final class BrowserMediaRowView: NSView {
    public static let width: CGFloat = 300

    private var media: BrowserMediaState
    private let onCommand: (BrowserMediaCommand) -> Void
    private let onReveal: () -> Void
    private let artwork = NSImageView()
    private lazy var playPause = button(.playPause)
    private lazy var mute = button(.toggleMute)

    public init(title: String, subtitle: String, media: BrowserMediaState, artwork image: NSImage?,
                onCommand: @escaping (BrowserMediaCommand) -> Void, onReveal: @escaping () -> Void) {
        self.media = media
        self.onCommand = onCommand
        self.onReveal = onReveal
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 96))
        artwork.image = image ?? NSImage.icon(.mediaHub, size: 20)
        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.wantsLayer = true
        artwork.layer?.cornerRadius = 6
        artwork.layer?.masksToBounds = true
        let titleLabel = label(title, font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
        let subtitleLabel = label(subtitle, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let header = NSStackView(views: [artwork, text])
        header.alignment = .centerY
        header.spacing = 10
        let previous = button(.previousTrack), next = button(.nextTrack)
        previous.isEnabled = media.actions.contains(.previoustrack)
        next.isEnabled = media.actions.contains(.nexttrack)
        let controls = NSStackView(views: [previous, playPause, next, mute])
        controls.spacing = 12
        for view in [header, controls] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            artwork.widthAnchor.constraint(equalToConstant: 40),
            artwork.heightAnchor.constraint(equalToConstant: 40),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            text.widthAnchor.constraint(lessThanOrEqualToConstant: Self.width - 78),
            controls.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            controls.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel([title, subtitle].filter { !$0.isEmpty }.joined(separator: ", "))
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The artwork, once loaded.
    public func setArtwork(_ image: NSImage) { artwork.image = image }

    public override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        onReveal()
    }

    @objc private func pressed(_ sender: NSButton) {
        let command: BrowserMediaCommand
        switch sender {
        case playPause: command = .playPause; media.isPlaying.toggle()
        case mute: command = .toggleMute; media.isMuted.toggle()
        default: command = sender.tag == 0 ? .previousTrack : .nextTrack
        }
        onCommand(command)
        update()
    }

    private func update() {
        playPause.setIcon(media.isPlaying ? .mediaPause : .mediaPlay, label: media.isPlaying ? Strings.mediaPause : Strings.mediaPlay)
        mute.setIcon(media.isMuted ? .mediaMuted : .mediaAudio, label: media.isMuted ? Strings.mediaUnmute : Strings.mediaMute)
    }

    private func button(_ command: BrowserMediaCommand) -> ChromeIconButton {
        let (icon, title): (IconName, String) = switch command {
        case .previousTrack: (.mediaPrevious, Strings.mediaPrevious)
        case .nextTrack: (.mediaNext, Strings.mediaNext)
        case .playPause: (.mediaPlay, Strings.mediaPlay)
        case .toggleMute: (.mediaAudio, Strings.mediaMute)
        }
        let view = ChromeIconButton(icon: icon, label: title, action: #selector(pressed(_:)), target: self, toolbar: true)
        view.tag = command == .previousTrack ? 0 : 1
        return view
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.isHidden = text.isEmpty
        return field
    }
}
