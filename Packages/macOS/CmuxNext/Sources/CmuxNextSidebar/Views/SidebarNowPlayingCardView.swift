import AppKit
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextWakeups

/// The Now Playing card in the bottom-left slot (cx-ouoxo): the artwork,
/// title and artist with small level bars that sway while it plays, a
/// scrubber that seeks, and Previous, Play or Pause (the one filled control),
/// and Next. It sits on the composer's surface like every sidebar card, in
/// the sidebar's theme. The bars and the scrubber move only when motion is
/// allowed (`Motion`), as render-server animations, so a playing card costs
/// the app no wakeups. Hovering it reveals an x at its top right (the
/// sidebar's hover-reveal fade, `setHoverShown`) that hides the card until
/// other media starts; a right-click opens the card's action menu (u2437).
final class SidebarNowPlayingCardView: NSView {
    var onCommand: ((SidebarNowPlayingCommand) -> Void)?
    /// The x: the slot sends ``SidebarIntent/hideNowPlayingCard``.
    var onClose: (() -> Void)?
    /// The right-click menu (the App's, from the action catalog's `nowPlayingCard` placements).
    var menuProvider: (() -> NSMenu?)?
    let closeButton = SidebarIconButton(icon: .actionClose, pointSize: { 9 }, label: SidebarNowPlayingCardView.closeLabel)
    /// The pointer is on the card: its x shows.
    private(set) var isHovered = false
    private var hoverArea: NSTrackingArea?
    private(set) var nowPlaying: SidebarNowPlaying?
    let surface = CardSurfaceView()
    let artworkView = DecorativeImageView()
    let titleLabel = ChromeLabel(labelWithString: "")
    let artistLabel = ChromeLabel(labelWithString: "")
    let scrubber = SidebarNowPlayingScrubber()
    let previousButton = SidebarIconButton(icon: .mediaPrevious, label: "")
    let playPauseButton = SidebarNowPlayingPlayButton()
    let levels = SidebarNowPlayingLevels()
    let nextButton = SidebarIconButton(icon: .mediaNext, label: "")
    /// The artwork data `artworkView` shows, so a report with the same art does not decode it again.
    private var shownArtwork: Data?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(surface)
        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = Metrics.space1
        artworkView.layer?.masksToBounds = true
        for label in [titleLabel, artistLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setAccessibilityElement(false)
        }
        for view in [artworkView, titleLabel, artistLabel, levels, scrubber, previousButton, playPauseButton, nextButton, closeButton] as [NSView] {
            addSubview(view)
        }
        closeButton.isHidden = true
        closeButton.alphaValue = 0
        closeButton.toolTip = Self.closeLabel
        closeButton.onPress = { [weak self] in self?.onClose?() }
        previousButton.onPress = { [weak self] in self?.onCommand?(.previous) }
        playPauseButton.onPress = { [weak self] in self?.onCommand?(.playPause) }
        nextButton.onPress = { [weak self] in self?.onCommand?(.next) }
        scrubber.onSeek = { [weak self] seconds in self?.onCommand?(.seek(seconds)) }
        for (view, control) in [(previousButton, "previous"), (playPauseButton, "playPause"), (nextButton, "next"), (scrubber, "scrubber")] as [(NSView, String)] {
            view.setAccessibilityIdentifier("cmux.sidebar.nowPlaying.\(control)")
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("cmux.sidebar.nowPlaying")
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    func configure(_ nowPlaying: SidebarNowPlaying?) {
        guard nowPlaying != self.nowPlaying else { return }
        self.nowPlaying = nowPlaying
        guard let nowPlaying else {
            isHidden = true
            scrubber.show(nil)
            // A card that comes back starts without its x until the pointer moves onto it.
            isHovered = false
            setHoverShown(closeButton, false, fades: false)
            fadeOpacity(levels, to: 1, fades: false)
            return
        }
        titleLabel.stringValue = nowPlaying.title
        artistLabel.stringValue = nowPlaying.artist
        artistLabel.isHidden = nowPlaying.artist.isEmpty
        let labels = nowPlaying.labels
        playPauseButton.icon = nowPlaying.isPlaying ? .mediaPause : .mediaPlay
        playPauseButton.label = nowPlaying.isPlaying ? labels.pause : labels.play
        previousButton.label = labels.previous
        nextButton.label = labels.next
        previousButton.isEnabled = nowPlaying.canPrevious
        nextButton.isEnabled = nowPlaying.canNext
        levels.show(playing: nowPlaying.isPlaying)
        if nowPlaying.artwork != shownArtwork {
            shownArtwork = nowPlaying.artwork
            artworkView.image = nowPlaying.artwork.flatMap(NSImage.init(data:))
        }
        setAccessibilityLabel([nowPlaying.title, nowPlaying.artist].filter { !$0.isEmpty }.joined(separator: ", "))
        scrubber.show(nowPlaying)
        applyColors()
        needsLayout = true
    }

    static var closeLabel: String {
        String(localized: "sidebar.nowPlaying.close", defaultValue: "Hide Media Card", bundle: .module)
    }

    /// Shows the x while the pointer is on the card, with the hover-reveal fade (instant under Reduce Motion).
    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        let shown = hovered && nowPlaying != nil
        setHoverShown(closeButton, shown, fades: window != nil)
        // The x takes the level bars' corner while it shows; the bars come back as it goes.
        fadeOpacity(levels, to: shown ? 0 : 1, fades: window != nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(false)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?() ?? super.menu(for: event)
    }

    private static var padding: CGFloat { Metrics.space3 }
    private static let artworkSide: CGFloat = 44
    private static let controlSide: CGFloat = 24
    private static let playSide: CGFloat = 32

    /// The card's height for `nowPlaying` at the sidebar's width.
    static func height(for nowPlaying: SidebarNowPlaying) -> CGFloat {
        let scrub = nowPlaying.canSeek ? SidebarNowPlayingScrubber.height + Metrics.space1 : 0
        return padding + artworkSide + Metrics.space2 + scrub + playSide + padding
    }

    override func layout() {
        super.layout()
        let b = bounds, pad = Self.padding, side = Self.artworkSide
        surface.frame = b
        surface.cornerRadius = Metrics.space3
        titleLabel.font = Typography.bodyEmphasized
        artistLabel.font = Typography.caption
        artworkView.frame = NSRect(x: pad, y: pad, width: side, height: side)
        artworkView.layer?.cornerRadius = Metrics.space2
        let textX = pad + side + Metrics.space2, levelsSize = SidebarNowPlayingLevels.size
        let textWidth = max(0, b.width - pad - textX - levelsSize.width - Metrics.space2)
        let title = ceil(Typography.bodyEmphasized.boundingRectForFont.height), artist = ceil(Typography.caption.boundingRectForFont.height)
        let textHeight = title + (artistLabel.isHidden ? 0 : artist)
        let textY = pad + max(0, (side - textHeight) / 2)
        titleLabel.frame = NSRect(x: textX, y: textY, width: textWidth, height: title)
        artistLabel.frame = NSRect(x: textX, y: textY + title, width: textWidth, height: artist)
        levels.frame = NSRect(x: b.width - pad - levelsSize.width, y: textY + (title - levelsSize.height) / 2,
                              width: levelsSize.width, height: levelsSize.height).integral
        var y = pad + side + Metrics.space2
        if nowPlaying?.canSeek == true {
            scrubber.frame = NSRect(x: pad, y: y, width: max(0, b.width - 2 * pad), height: SidebarNowPlayingScrubber.height)
            y += SidebarNowPlayingScrubber.height + Metrics.space1
        } else {
            scrubber.frame = .zero
        }
        let control = Self.controlSide, play = Self.playSide, gap = Metrics.space4
        let x = (b.width - 2 * control - play - 2 * gap) / 2
        previousButton.frame = NSRect(x: x, y: y + (play - control) / 2, width: control, height: control).integral
        playPauseButton.frame = NSRect(x: x + control + gap, y: y, width: play, height: play).integral
        nextButton.frame = NSRect(x: x + control + gap + play + gap, y: y + (play - control) / 2, width: control, height: control).integral
        let close = Self.closeSide
        closeButton.frame = NSRect(x: b.width - Metrics.space1 - close, y: Metrics.space1, width: close, height: close).integral
    }

    private static let closeSide: CGFloat = 18

    private func applyColors() {
        performWithTheme {
            titleLabel.textColor = Palette.textPrimary
            artistLabel.textColor = Palette.textSecondary
            artworkView.layer?.backgroundColor = Palette.hoverFill.cgColor
            scrubber.applyColors()
        }
        levels.applyColors()
        playPauseButton.needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        surface.needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
        scrubber.show(nowPlaying)
    }
}

/// The card's scrubber: a thin track with the played part filled. A click
/// or a drag seeks; VoiceOver reads it as a slider (the position now) that
/// steps by ten seconds. While playing, the fill runs to the end as one
/// Core Animation, so the app sets no timer: a steady glide, or under
/// Reduce Motion a step every few seconds, with no sliding in between.
final class SidebarNowPlayingScrubber: NSView {
    static let height: CGFloat = 12
    private static let barHeight: CGFloat = 3
    static let progressKey = "progress"
    var onSeek: ((TimeInterval) -> Void)?
    private(set) var nowPlaying: SidebarNowPlaying?
    private let track = CALayer()
    let fill = CALayer()
    /// The position a drag shows until the source reports again, or until ``seekWait`` passes
    /// with no report (a source that ignored the seek): then it runs on from where it plays.
    private var dragged: TimeInterval?
    private let seekWait = DemandTimer(owner: "sidebar.now-playing.seek")
    /// Bumped by each press and release, so a wait that fires as a new drag starts leaves that drag.
    private var seekCount = 0
    static let seekWaitDelay: Duration = .seconds(2)
    /// Pins Reduce Motion for this scrubber only (tests), instead of the
    /// process-wide `Motion.reduceMotionOverride`, which leaks into every
    /// test that runs alongside.
    var reduceMotionOverride: Bool?
    private let formatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(track)
        track.addSublayer(fill)
        fill.anchorPoint = .zero
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(Strings.nowPlayingPosition)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    func show(_ nowPlaying: SidebarNowPlaying?) {
        self.nowPlaying = nowPlaying
        dragged = nil
        seekWait.cancel()
        isHidden = nowPlaying?.canSeek != true
        update()
    }

    func applyColors() {
        performWithTheme {
            track.backgroundColor = Palette.hoverFill.cgColor
            fill.backgroundColor = Palette.textSecondary.cgColor
        }
    }

    override func layout() {
        super.layout()
        update()
    }

    /// Draws the played part for now and, when motion is allowed and it plays, lets it run to the end.
    private func update() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        fill.removeAnimation(forKey: Self.progressKey)
        let bar = Self.barHeight, width = bounds.width
        track.frame = NSRect(x: 0, y: (bounds.height - bar) / 2, width: width, height: bar)
        track.cornerRadius = bar / 2
        fill.cornerRadius = bar / 2
        guard let nowPlaying, let duration = nowPlaying.duration, duration > 0 else {
            fill.bounds = .zero
            return
        }
        let position = dragged ?? nowPlaying.position(at: Date()) ?? 0
        fill.position = .zero
        fill.bounds = CGRect(x: 0, y: 0, width: width * position / duration, height: bar)
        guard dragged == nil, nowPlaying.isPlaying, nowPlaying.rate > 0, window != nil, width > 0, position < duration else { return }
        let remaining = (duration - position) / nowPlaying.rate
        let glides = reduceMotionOverride.map { !$0 } ?? Motion.overlays.animatesMovement
        fill.add(Self.progress(from: fill.bounds.width, to: width, over: remaining, glides: glides), forKey: Self.progressKey)
    }

    /// The fill running to the end of the track: a linear glide, or (Reduce
    /// Motion) discrete steps every `step` seconds of playback.
    static func progress(from start: CGFloat, to end: CGFloat, over seconds: TimeInterval, glides: Bool) -> CAAnimation {
        // motion-allow: playback progress runs on the track's clock, not a UI motion token.
        let run = CAKeyframeAnimation(keyPath: "bounds.size.width")
        if glides {
            run.values = [start, end]
            run.timingFunction = CAMediaTimingFunction(name: .linear) // motion-allow: the track plays at a constant rate.
        } else {
            let steps = max(1, min(720, Int((seconds / 5).rounded(.up))))
            run.values = (0...steps).map { start + (end - start) * CGFloat($0) / CGFloat(steps) }
            run.calculationMode = .discrete
        }
        run.duration = seconds
        run.fillMode = .forwards
        run.isRemovedOnCompletion = false
        return run
    }

    override func accessibilityValue() -> Any? {
        guard let nowPlaying, let duration = nowPlaying.duration, let position = dragged ?? nowPlaying.position(at: Date()) else { return nil }
        return [position, duration].compactMap { formatter.string(from: $0) }.joined(separator: " / ")
    }

    private func seconds(at event: NSEvent) -> TimeInterval? {
        guard let duration = nowPlaying?.duration, duration > 0, bounds.width > 0 else { return nil }
        let x = convert(event.locationInWindow, from: nil).x
        return duration * min(max(0, x / bounds.width), 1)
    }

    override func mouseDown(with event: NSEvent) {
        guard let seconds = seconds(at: event) else { return }
        seekWait.cancel()
        seekCount &+= 1
        dragged = seconds
        update()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragged != nil, let seconds = seconds(at: event) else { return }
        dragged = seconds
        update()
    }

    override func mouseUp(with event: NSEvent) {
        guard dragged != nil, let seconds = seconds(at: event) ?? dragged else { return }
        // A seek close to where it plays changes nothing the source reports: run on from there.
        let expected = nowPlaying?.position(at: Date())
        dragged = expected.map { abs($0 - seconds) < 1.5 } == true ? nil : seconds
        update()
        seekCount &+= 1
        if dragged != nil {
            let seek = seekCount
            seekWait.schedule(after: Self.seekWaitDelay) { @MainActor [weak self] in
                guard let self, self.seekCount == seek else { return }
                self.dragged = nil
                self.update()
            }
        }
        onSeek?(seconds)
    }

    override func accessibilityPerformIncrement() -> Bool { step(by: 10) }
    override func accessibilityPerformDecrement() -> Bool { step(by: -10) }

    private func step(by seconds: TimeInterval) -> Bool {
        guard let nowPlaying, let duration = nowPlaying.duration, let position = nowPlaying.position(at: Date()) else { return false }
        onSeek?(min(max(0, position + seconds), duration))
        return true
    }
}
