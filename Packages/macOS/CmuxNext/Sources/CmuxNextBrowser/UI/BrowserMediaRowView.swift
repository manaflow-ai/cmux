public import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// One tab's card in the media hub menu (Edge's Now Playing, cx-6qwm.2):
/// artwork, title, artist and site, then Previous, Play or Pause, Next,
/// Mute and, for a video, Picture in Picture. A control runs `onCommand` and keeps the menu open (the row flips
/// its own Play/Pause and Mute at once; the page's next report confirms
/// them); a click elsewhere on the card runs `onReveal` and closes the
/// menu. Previous and Next are off when the page handles no such action.
public final class BrowserMediaRowView: NSView {
    public static let width: CGFloat = 300

    private var media: BrowserMediaState
    /// Offers Picture in Picture for a video (`media.pictureInPicture.enabled`), read at each update
    /// and press, so a card left open after the setting turns off neither floats nor flips its button.
    private var offersPictureInPicture: () -> Bool
    private var onCommand: (BrowserMediaCommand) -> Void
    private var onReveal: () -> Void
    private let artwork = NSImageView()
    private let titleLabel = ChromeLabel(labelWithString: "")
    private let subtitleLabel = ChromeLabel(labelWithString: "")
    private lazy var previous = button(.previousTrack)
    private lazy var next = button(.nextTrack)
    /// The artwork address last loaded (`BrowserMediaRows` keeps a loaded image).
    public var artworkURL: URL?
    private lazy var playPause = button(.playPause)
    private lazy var mute = button(.toggleMute)
    private lazy var pictureInPicture = button(.pictureInPicture)

    public init(title: String, subtitle: String, media: BrowserMediaState, artwork image: NSImage?,
                pictureInPicture offers: @escaping () -> Bool = { true },
                onCommand: @escaping (BrowserMediaCommand) -> Void, onReveal: @escaping () -> Void) {
        self.media = media
        offersPictureInPicture = offers
        self.onCommand = onCommand
        self.onReveal = onReveal
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 96))
        artwork.image = image ?? NSImage.icon(.browserToolbarMedia, size: 20)
        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.wantsLayer = true
        artwork.layer?.cornerRadius = 6
        artwork.layer?.masksToBounds = true
        style(titleLabel, title, font: .systemFont(ofSize: TypeScale.body, weight: TypeScale.emphasis), color: .labelColor)
        style(subtitleLabel, subtitle, font: .systemFont(ofSize: TypeScale.caption, weight: TypeScale.regular), color: .secondaryLabelColor)
        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let header = NSStackView(views: [artwork, text])
        header.alignment = .centerY
        header.spacing = 10
        previous.isEnabled = media.actions.contains(.previoustrack)
        next.isEnabled = media.actions.contains(.nexttrack)
        let controls = NSStackView(views: [previous, playPause, next, mute, pictureInPicture])
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

    /// Shows another state in place: the media hub reuses a tab's card between opens instead of
    /// building its labels, stacks and four buttons again (u2426).
    public func show(title: String, subtitle: String, media: BrowserMediaState, artwork image: NSImage?,
                     pictureInPicture offers: @escaping () -> Bool = { true },
                     onCommand: @escaping (BrowserMediaCommand) -> Void, onReveal: @escaping () -> Void) {
        self.media = media
        offersPictureInPicture = offers
        self.onCommand = onCommand
        self.onReveal = onReveal
        if titleLabel.stringValue != title { titleLabel.stringValue = title }
        if subtitleLabel.stringValue != subtitle { subtitleLabel.stringValue = subtitle }
        titleLabel.isHidden = title.isEmpty
        subtitleLabel.isHidden = subtitle.isEmpty
        if let image, artworkURL == nil { artwork.image = image }
        previous.isEnabled = media.actions.contains(.previoustrack)
        next.isEnabled = media.actions.contains(.nexttrack)
        setAccessibilityLabel([title, subtitle].filter { !$0.isEmpty }.joined(separator: ", "))
        update()
    }

    /// Shows whether the page's video floats now (`floating`, read from the tab), after a Picture in
    /// Picture press the app refused once the card showed it (the setting turned off before the press
    /// reached the page). Sets the state rather than flipping it, so a late refusal never inverts a
    /// card that was shown again meanwhile; while the setting is off the button hides.
    public func showPictureInPicture(_ floating: Bool) {
        media.isPictureInPicture = floating
        update()
    }

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
        case pictureInPicture:
            // Turned off while the card showed: the button goes and nothing floats.
            guard offersPictureInPicture() else { return update() }
            command = .pictureInPicture; media.isPictureInPicture.toggle()
        default: command = sender.tag == 0 ? .previousTrack : .nextTrack
        }
        onCommand(command)
        update()
    }

    private func update() {
        playPause.setIcon(media.isPlaying ? .browserTabPause : .browserTabPlay, label: media.isPlaying ? Strings.mediaPause : Strings.mediaPlay)
        mute.setIcon(media.isMuted ? .browserTabMuted : .browserTabAudio, label: media.isMuted ? Strings.mediaUnmute : Strings.mediaMute)
        pictureInPicture.isHidden = !media.isVideo || !offersPictureInPicture()
        pictureInPicture.setIcon(Self.pictureInPictureIcon,
                                 label: media.isPictureInPicture ? Strings.mediaExitPictureInPicture : Strings.mediaPictureInPicture)
    }

    private func button(_ command: BrowserMediaCommand) -> ChromeIconButton {
        let (icon, title): (IconName, String) = switch command {
        case .previousTrack: (.mediaPrevious, Strings.mediaPrevious)
        case .nextTrack: (.mediaNext, Strings.mediaNext)
        case .playPause, .play, .pause: (.mediaPlay, Strings.mediaPlay)
        case .toggleMute, .muteTab, .seek: (.mediaAudio, Strings.mediaMute)
        case .pictureInPicture: (Self.pictureInPictureIcon, Strings.mediaPictureInPicture)
        }
        let view = ChromeIconButton(icon: icon, label: title, action: #selector(pressed(_:)), target: self, toolbar: true)
        view.tag = command == .previousTrack ? 0 : 1
        return view
    }

    /// The PiP glyph Page Info's permission row uses too.
    static let pictureInPictureIcon = IconName.sitePermissionAutopictureinpicture

    private func style(_ field: ChromeLabel, _ text: String, font: NSFont, color: NSColor) {
        field.stringValue = text
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.isHidden = text.isEmpty
    }
}
