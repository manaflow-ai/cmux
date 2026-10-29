public import AppKit
public import AVFoundation
public import CmuxNextCompat
import CmuxNextWakeups
public import CmuxNextDesignTokens
public import CmuxNextAppearance

/// A video wallpaper behind a window's content (cx-14vdf): the file loops, muted, through
/// `AVPlayerLayer`, filling the window as the art does. It plays only while someone can see it
/// and the Mac can afford it, and holds its frame otherwise:
///
/// - the window's node (``WindowVisibilitySource``) is seen: not occluded, minimized, hidden with
///   the app or on sleeping screens, or a capture vote holds it (``VisibilityNode/wantsFrames``);
///   the session is the active one, and other windows hide less than nearly all of it
///   (``BackdropCoverage``: AppKit calls a window visible while any pixel of it shows);
/// - not in Low Power Mode, and the thermal state is below serious (the App pushes both from its
///   energy monitor, ``BackdropVideoPlayers/setEnergy(lowPowerMode:thermal:)``);
/// - looping motion is allowed (`Motion.animatesLoops`: Reduce Motion or animation speed "off"
///   holds the frame it is on; before the first frame the art view below shows the poster).
///
/// Every window showing one file shares one decoder (``BackdropVideoPlayers``), as idlesse found
/// one decoder per display doubled the video decoder's load; a 0.5 s forward buffer keeps 4K
/// frames out of memory, and the layer stays clear until its first frame is ready, so a new
/// window never flashes black. The first frame fades in over the poster, and a video no one has
/// been able to see for a minute gives its decoder back (``BackdropVideoPlayers/releaseAfter``).
///
/// Its window's key, main and close notices come through the window's one ``WindowEvents``; the
/// session's through its players (``BackdropVideoPlayers/follow(deadlines:session:)``); its coverage
/// samples are a `background` ``MainDeadline`` on the players' scheduler.
public final class BackdropVideoView: NSView {
    /// The file shown, nil when the wallpaper is no video.
    public private(set) var url: URL?
    /// The layer the shared player draws into.
    public let playerLayer = AVPlayerLayer()
    /// Tests: pins Reduce Motion, Low Power Mode or visibility for this view instead of the system's
    /// (for Low Power Mode, instead of its players' energy inputs).
    public var reduceMotionOverride: Bool? { didSet { update() } }
    public var lowPowerOverride: Bool? { didSet { update() } }
    public var visibleOverride: Bool? { didSet { update() } }
    /// Tests: the windows above this one, in place of the screen's.
    public var windowsAboveOverride: (() -> [BackdropCoverage.Window])?
    let players: BackdropVideoPlayers
    /// Its window's key, main and close notices.
    private var windowWatch: [EventSubscription] = []
    private var motionWatch: AppearanceSignals.Subscription? // Reduce Motion, the speed or a motion switch
    private var readyObservation: NSKeyValueObservation?
    /// Its window's node (``WindowVisibilitySource``); nil out of a window.
    private var windowNode: VisibilityNode?
    /// The node's flips and capture votes.
    private var nodeWatch: [VisibilitySubscription] = []
    var coverage = BackdropCoverage()
    /// The next coverage sample, on the players' scheduler (nil until the first, or with none).
    private var coverageDeadline: MainDeadline?
    /// The window list a coverage sample waits for: at most one at a time, cancelled when sampling stops.
    var coverageSample: Task<Void, Never>?

    public init(frame frameRect: NSRect, players: BackdropVideoPlayers = .shared) {
        self.players = players
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.opacity = 0
        layer?.addSublayer(playerLayer)
        isHidden = true
        setAccessibilityElement(false)
        players.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    override public func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    /// Shows `url` looping (nil: no video). The same file keeps its player and position.
    public func show(_ url: URL?) {
        guard url != self.url else { return update() }
        detach()
        self.url = url
        isHidden = url == nil
        attach()
    }

    /// Holds the shared player only while in a window, so a closed window releases its decoder.
    private func attach() {
        guard let url, window != nil, playerLayer.player == nil else { return update() }
        playerLayer.opacity = 0
        playerLayer.player = players.attach(url, viewer: ObjectIdentifier(self))
        // raw-observer-allow: the layer's readiness has no notice; KVO is AVFoundation's only report of it
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            // main-hop-allow: AVFoundation reports readiness from its own queue: inline on main (the .initial report,
            // this turn), else one hop per readiness change (the first frame, a released decoder)
            MainDelivery().run { self?.showFrames(ready) }
        }
        update()
    }

    private func detach() {
        readyObservation = nil
        stopCoverage()
        guard let url, playerLayer.player != nil else { return }
        players.detach(url, viewer: ObjectIdentifier(self))
        playerLayer.player = nil
        playerLayer.opacity = 0
    }

    /// Whether the shared player runs for this view now.
    public var isPlaying: Bool { (playerLayer.player?.rate ?? 0) > 0 }

    /// Whether this view asks its player to run: shown, seen, and allowed to move.
    public var wantsPlayback: Bool { seen && !coverage.resting }

    /// Whether someone could see the video now: on screen, uncovered, the screens awake. A video
    /// held for Low Power Mode or Reduce Motion is still seen and keeps its frame and decoder.
    public var canBeSeen: Bool { onScreen && !coverage.resting }

    /// Everything ``wantsPlayback`` asks but coverage, which is sampled only while this holds.
    private var seen: Bool {
        let lowPower = lowPowerOverride ?? players.lowPowerMode
        let reduced = reduceMotionOverride ?? !Motion.panes.animatesLoops
        let hot = players.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        return onScreen && !lowPower && !hot && !reduced
    }

    /// Shown in a window whose node is seen (on screen with the screens awake, or captured), with
    /// the session active.
    private var onScreen: Bool {
        guard url != nil, !isHidden, window != nil else { return false }
        let visible = visibleOverride ?? (windowNode?.wantsFrames ?? false)
        return visible && !players.sessionInactive
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowWatch = []
        motionWatch = nil
        for subscription in nodeWatch { subscription.cancel() }
        nodeWatch = []
        windowNode = nil
        guard let window else { return detach() }
        follow(WindowVisibilitySource.of(window).node)
        observe()
        attach()
    }

    /// Plays and holds by `node`: its flips (occlusion, minimize, app hide, screens asleep) and its
    /// capture votes.
    private func follow(_ node: VisibilityNode) {
        windowNode = node
        nodeWatch = [
            node.subscribe(owner: "BackdropVideoView") { [weak self] _ in self?.update() },
            node.subscribeExemption(owner: "BackdropVideoView") { [weak self] in self?.update() },
        ]
    }

    override public var isHidden: Bool {
        didSet { if isHidden != oldValue { update() } }
    }

    /// The first frame fades in over the poster (as long as the motion policy's fade, shorter
    /// under Reduce Motion); frames that stop
    /// (a released decoder) hide at once, leaving the poster below.
    private func showFrames(_ ready: Bool) {
        if ready, playerLayer.opacity == 0, window != nil {
            Motion.panes.set(playerLayer, "opacity", to: Float(1), fade: .fadeIn, from: Float(0))
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.removeAnimation(forKey: "opacity")
        playerLayer.opacity = ready ? 1 : 0
        CATransaction.commit()
    }

    /// Low Power Mode, the thermal state or the session changed (``BackdropVideoPlayers/setEnergy(lowPowerMode:thermal:)``,
    /// ``BackdropVideoPlayers/follow(deadlines:session:)``).
    func inputsDidChange() {
        update()
    }

    func update() {
        guard let url, playerLayer.player != nil else { return stopCoverage() }
        if seen {
            startCoverage()
        } else {
            stopCoverage()
        }
        players.setPlaying(wantsPlayback, seen: canBeSeen, url, viewer: ObjectIdentifier(self))
    }

    private func startCoverage() {
        guard coverageDeadline?.isScheduled != true else { return }
        scheduleCoverage()
    }

    /// The next sample, a `background` deadline: nobody sees the window list it reads.
    private func scheduleCoverage() {
        guard let deadlines = players.deadlines else { return }
        let deadline = coverageDeadline
            ?? MainDeadline(owner: "BackdropVideoView.coverage", workClass: .background, scheduler: deadlines)
        coverageDeadline = deadline
        deadline.schedule(after: .seconds(BackdropCoverage.interval)) { [weak self] in
            self?.coverageFired()
        }
    }

    /// One sample a deadline, then the next deadline while the video is still seen.
    private func coverageFired() {
        sampleCoverage()
        if seen, url != nil, playerLayer.player != nil { scheduleCoverage() }
    }

    /// Stops sampling; coverage seen before the window was hidden or closed is stale.
    private func stopCoverage() {
        coverageDeadline?.cancel()
        coverageSample?.cancel()
        coverageSample = nil
        coverage.reset()
    }

    /// Follows the window's notices (occlusion, minimize, app hide and screen sleep reach it through its window's
    /// node, follow(_:); the session through its players).
    private func observe() {
        guard let window else { return }
        motionWatch = DesignSettings.shared.signals.subscribe([.motion], owner: "BackdropVideoView") { [weak self] in self?.update() }
        let events = WindowEvents.of(window)
        windowWatch = [
            // A window brought to the front shows: play now; the next samples rest it again if needed.
            events.subscribe(NSWindow.didBecomeMainNotification, owner: "BackdropVideoView") { [weak self] in self?.broughtToFront() },
            events.subscribe(NSWindow.didBecomeKeyNotification, owner: "BackdropVideoView") { [weak self] in self?.broughtToFront() },
            // A closed window keeps its views: hand the shared player back now, not when the view goes.
            events.subscribe(NSWindow.willCloseNotification, owner: "BackdropVideoView") { [weak self] in self?.detach() },
        ]
    }

    private func broughtToFront() {
        coverage.reset()
        update()
    }
}
