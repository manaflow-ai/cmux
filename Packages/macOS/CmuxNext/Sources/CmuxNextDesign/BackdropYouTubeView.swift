public import AppKit
import CmuxNextWakeups
public import CmuxNextDesignTokens

/// A YouTube video behind a window's content (``BackdropYouTube``), over its poster in the art
/// view below. It plays on the video wallpaper's terms, asked of the Rust scheduler
/// (``BackdropPlayback``) as an exclusive player:
///
/// - the window is visible, the screens awake, the session active, not in Low Power Mode or hot,
///   looping motion allowed, and someone at the Mac (`appearance.videoWallpaperIdlePause`);
/// - more than half of the window shows (``BackdropCoverage/halfVisible``, sampled every 3 s
///   while it could play) and the window is at least 200 pt a side;
/// - it is the frontmost such window: one YouTube player plays app-wide
///   (``BackdropYouTubePlayers``), every other window shows the poster.
///
/// It owns no observers: the window's video wallpaper view (``BackdropVideoView``) tells it of
/// every change through `WindowMaterialView`, as it tells the living wallpaper.
///
/// The player is laid out at 16:9 with the video's quality as its height in pixels
/// (``BackdropYouTube/playerSize(backingScale:)``), so YouTube sends at most that stream, and the
/// host scales it to fill the window. It takes no clicks, keys or focus, is not in the
/// accessibility tree, and stays clear until its first frame plays, then fades in over the poster.
public final class BackdropYouTubeView: NSView {
    /// The video shown, nil when the wallpaper is no YouTube video.
    public private(set) var video: BackdropYouTube?
    /// Holds the player at its own size, scaled to fill this view.
    let playerHost = BackdropYouTubeHost()
    /// Tests: pins Reduce Motion, Low Power Mode, visibility or the size for this view.
    public var reduceMotionOverride: Bool? { didSet { update() } }
    public var lowPowerOverride: Bool? { didSet { update() } }
    public var visibleOverride: Bool? { didSet { update() } }
    /// Tests: the windows above this one, in place of the screen's.
    public var windowsAboveOverride: (() -> [BackdropCoverage.Window])?
    /// The window's sleep and session state, which the video wallpaper view watches.
    var sight: (() -> (screensAsleep: Bool, sessionInactive: Bool))?
    private let players: BackdropYouTubePlayers
    private let idle: BackdropIdle
    private var coverage = BackdropCoverage(restAt: BackdropCoverage.halfVisible.rest, resumeAt: BackdropCoverage.halfVisible.resume)
    private let coverageTimer = DemandTimer(owner: "backdrop-youtube-coverage")
    private var samplesCoverage = false
    /// The scheduler's last answer (tests, `debug.themes`).
    public private(set) var playback: BackdropPlayback?

    public init(frame frameRect: NSRect, players: BackdropYouTubePlayers, idle: BackdropIdle) {
        self.players = players
        self.idle = idle
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        playerHost.wantsLayer = true
        playerHost.layer?.opacity = 0
        addSubview(playerHost)
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }
    override public func isAccessibilityElement() -> Bool { false }
    override public func accessibilityChildren() -> [Any]? { [] }

    /// Shows `video` (nil: none). The same video keeps its player and place.
    public func show(_ video: BackdropYouTube?) {
        guard video != self.video else { return update() }
        if self.video != nil { players.leave(self) }
        self.video = video
        isHidden = video == nil
        needsLayout = true
        update()
    }

    /// Whether this window plays the video now.
    public var isPlaying: Bool { playback?.plays ?? false }

    override public var isHidden: Bool {
        didSet { if isHidden != oldValue { update() } }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        update()
    }

    override public func layout() {
        super.layout()
        placePlayer()
        // The size decides the 200 pt minimum.
        if video != nil { update() }
    }

    /// Lays the host over the view and the player in it at the video's player size.
    private func placePlayer() {
        guard let video else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let geometry = Self.geometry(view: bounds.size, player: video.playerSize(backingScale: scale))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerHost.frame = bounds
        playerHost.bounds = CGRect(origin: .zero, size: geometry.hostBounds)
        playerHost.subviews.first?.frame = geometry.playerFrame
        CATransaction.commit()
    }

    /// Aspect fill: the host's bounds (smaller than the view by the fill scale, so AppKit scales
    /// its content up to the view) and the player's frame centered in them.
    nonisolated static func geometry(view: CGSize, player: CGSize) -> (hostBounds: CGSize, playerFrame: CGRect) {
        guard view.width > 0, view.height > 0, player.width > 0, player.height > 0 else {
            return (view, CGRect(origin: .zero, size: player))
        }
        let scale = max(view.width / player.width, view.height / player.height)
        let host = CGSize(width: view.width / scale, height: view.height / scale)
        let origin = CGPoint(x: (host.width - player.width) / 2, y: (host.height - player.height) / 2)
        return (host, CGRect(origin: origin, size: player))
    }

    /// The window's visibility, power, heat, motion or closing changed (told by the video
    /// wallpaper view's observers through `WindowMaterialView`).
    public func sightChanged(closing: Bool = false) {
        guard !closing else {
            stopCoverage()
            idle.unwatch(self)
            return players.leave(self)
        }
        update()
    }

    /// Another window was chosen to play, or this one was.
    func choiceChanged() { update() }

    /// Asks the scheduler and tells the players what this window would do.
    func update() {
        guard let video, !isHidden, let window else {
            playback = nil
            stopCoverage()
            idle.unwatch(self)
            return players.leave(self)
        }
        let state = sight?() ?? (screensAsleep: false, sessionInactive: false)
        var terms = BackdropPlayback.terms(window, visibleOverride: visibleOverride, lowPowerOverride: lowPowerOverride,
                                           reduceMotionOverride: reduceMotionOverride, screensAsleep: state.screensAsleep,
                                           sessionInactive: state.sessionInactive)
        terms.covered = coverage.resting
        terms.secondsSinceInput = idle.secondsSinceInput
        terms.idleAfter = idle.idleAfter
        terms.exclusive = true
        terms.size = bounds.size
        // Whether it would play if it were the chosen window, then as it is.
        terms.chosen = true
        let ifChosen = BackdropPlayback(terms)
        terms.chosen = players.isChosen(self)
        let answer = BackdropPlayback(terms)
        playback = answer
        if BackdropPlayback.samplesCoverage(terms) { startCoverage() } else { stopCoverage() }
        if ifChosen.plays || ifChosen.idle {
            idle.watch(self, idle: ifChosen.idle) { [weak self] in self?.update() }
        } else {
            idle.unwatch(self)
        }
        players.report(self, video: video, window: window.windowNumber, eligible: ifChosen.plays, seen: answer.canBeSeen)
    }

    // MARK: The player

    /// Puts the shared player in this window (it moves from wherever it was, keeping its place).
    func adopt(_ player: any BackdropYouTubePlaying) {
        guard player.view.superview !== playerHost else { return }
        player.view.removeFromSuperview()
        playerHost.subviews.forEach { $0.removeFromSuperview() }
        playerHost.addSubview(player.view)
        placePlayer()
        setOpacity(player.hasPlayed ? 1 : 0)
    }

    /// The player left this window: the poster below shows.
    func dropPlayer() {
        playerHost.subviews.forEach { $0.removeFromSuperview() }
        setOpacity(0)
    }

    /// The first frame plays: it fades in over the poster (the motion policy's fade).
    func playerStarted() {
        guard !playerHost.subviews.isEmpty, playerHost.layer?.opacity == 0, let layer = playerHost.layer else { return }
        Motion.panes.set(layer, "opacity", to: Float(1), fade: .fadeIn, from: Float(0))
    }

    private func setOpacity(_ opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerHost.layer?.removeAnimation(forKey: "opacity")
        playerHost.layer?.opacity = opacity
        CATransaction.commit()
    }

    // MARK: Coverage

    /// Samples how much of the window other windows hide; it rests at half.
    public func sampleCoverage() {
        guard let window else { return }
        let above = windowsAboveOverride?() ?? BackdropCoverage.windows(above: window.windowNumber)
        let resting = coverage.resting
        coverage.sample(BackdropCoverage.covered(BackdropVideoView.screenFrame(window.frame), by: above,
                                                 ignoring: BackdropVideoView.descendants(of: window)))
        if coverage.resting != resting { update() }
    }

    private func startCoverage() {
        samplesCoverage = true
        guard !coverageTimer.isScheduled else { return }
        scheduleCoverage()
    }

    private func scheduleCoverage() {
        coverageTimer.schedule(after: .seconds(BackdropCoverage.interval)) { @MainActor [weak self] in
            self?.coverageFired()
        }
    }

    /// One sample a deadline, then the next while it still could play.
    private func coverageFired() {
        sampleCoverage()
        if samplesCoverage, video != nil { scheduleCoverage() }
    }

    private func stopCoverage() {
        samplesCoverage = false
        coverageTimer.cancel()
        coverage = BackdropCoverage(restAt: BackdropCoverage.halfVisible.rest, resumeAt: BackdropCoverage.halfVisible.resume)
    }
}

/// The player's host: decoration only, out of hit testing and the accessibility tree.
final class BackdropYouTubeHost: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
}
