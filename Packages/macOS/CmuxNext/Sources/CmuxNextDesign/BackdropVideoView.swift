public import AppKit
public import AVFoundation
import CmuxNextWakeups
public import CmuxNextDesignTokens

/// A video wallpaper behind a window's content (cx-14vdf): the file loops, muted, through
/// `AVPlayerLayer`, filling the window as the art does. It plays only while someone can see it
/// and the Mac can afford it, and holds its frame otherwise:
///
/// - the window is visible (not occluded, minimized or hidden with the app), the screens are
///   awake and the session is the active one, and other windows hide less than nearly all of it
///   (``BackdropCoverage``: AppKit calls a window visible while any pixel of it shows);
/// - not in Low Power Mode, and the thermal state is below serious;
/// - looping motion is allowed (`Motion.animatesLoops`: Reduce Motion or animation speed "off"
///   holds the frame it is on; before the first frame the art view below shows the poster).
///
/// Every window showing one file shares one decoder (``BackdropVideoPlayers``), as idlesse found
/// one decoder per display doubled the video decoder's load; a 0.5 s forward buffer keeps 4K
/// frames out of memory, and the layer stays clear until its first frame is ready, so a new
/// window never flashes black. The first frame fades in over the poster, and a video no one has
/// been able to see for a minute gives its decoder back (``BackdropVideoPlayers/releaseAfter``).
public final class BackdropVideoView: NSView {
    /// The file shown, nil when the wallpaper is no video.
    public private(set) var url: URL?
    /// The layer the shared player draws into.
    public let playerLayer = AVPlayerLayer()
    /// Tests: pins Reduce Motion, Low Power Mode or visibility for this view instead of the system's.
    public var reduceMotionOverride: Bool? { didSet { update() } }
    public var lowPowerOverride: Bool? { didSet { update() } }
    public var visibleOverride: Bool? { didSet { update() } }
    /// Tests: the windows above this one, in place of the screen's.
    public var windowsAboveOverride: (() -> [BackdropCoverage.Window])?
    private let players: BackdropVideoPlayers
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var readyObservation: NSKeyValueObservation?
    private var screensAsleep = false
    private var sessionInactive = false
    private var coverage = BackdropCoverage()
    private let coverageTimer = DemandTimer(owner: "backdrop-video-coverage")

    public init(frame frameRect: NSRect, players: BackdropVideoPlayers = .shared) {
        self.players = players
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.opacity = 0
        layer?.addSublayer(playerLayer)
        isHidden = true
        setAccessibilityElement(false)
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
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            // AVFoundation may report readiness from its own threads: inline on main, a hop otherwise.
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
        let lowPower = lowPowerOverride ?? ProcessInfo.processInfo.isLowPowerModeEnabled
        let reduced = reduceMotionOverride ?? !Motion.panes.animatesLoops
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        return onScreen && !lowPower && !hot && !reduced
    }

    /// Shown in a window that is on screen, with the screens awake and the session active.
    private var onScreen: Bool {
        guard url != nil, !isHidden, let window else { return false }
        let visible = visibleOverride ?? (window.occlusionState.contains(.visible) && !window.isMiniaturized && !NSApp.isHidden)
        return visible && !screensAsleep && !sessionInactive
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        guard window != nil else { return detach() }
        observe()
        attach()
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

    private func update() {
        guard let url, playerLayer.player != nil else { return stopCoverage() }
        if seen {
            startCoverage()
        } else {
            stopCoverage()
        }
        players.setPlaying(wantsPlayback, seen: canBeSeen, url, viewer: ObjectIdentifier(self))
    }

    /// Samples how much of the window other windows hide, and rests or resumes the video on it.
    public func sampleCoverage() {
        guard let window else { return }
        let above = windowsAboveOverride?() ?? BackdropCoverage.windows(above: window.windowNumber)
        let resting = coverage.resting
        coverage.sample(BackdropCoverage.covered(Self.screenFrame(window.frame), by: above, ignoring: Self.descendants(of: window)))
        if coverage.resting != resting { update() }
    }

    /// The numbers of a window's child windows, theirs, and so on: its overlay panel and page windows.
    static func descendants(of window: NSWindow) -> Set<Int> {
        var numbers: Set<Int> = []
        var pending = window.childWindows ?? []
        while let child = pending.popLast() {
            // A child never put on screen has no number yet; 0 would hide every unnumbered window.
            if child.windowNumber > 0 { numbers.insert(child.windowNumber) }
            pending += child.childWindows ?? []
        }
        return numbers
    }

    /// A window frame in CGWindowList's space: origin at the top left of the main display.
    static func screenFrame(_ frame: NSRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? frame.maxY
        return CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
    }

    private func startCoverage() {
        guard !coverageTimer.isScheduled else { return }
        scheduleCoverage()
    }

    private func scheduleCoverage() {
        coverageTimer.schedule(after: .seconds(BackdropCoverage.interval)) { @MainActor [weak self] in
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
        coverageTimer.cancel()
        coverage.reset()
    }

    private func observe() {
        let app = NotificationCenter.default, workspace = NSWorkspace.shared.notificationCenter
        var names: [(NotificationCenter, Notification.Name, AnyObject?)] = [
            (app, NSWindow.didChangeOcclusionStateNotification, window), (app, NSWindow.didMiniaturizeNotification, window),
            (app, NSWindow.didDeminiaturizeNotification, window), (app, NSWindow.didBecomeMainNotification, window),
            (app, NSWindow.didBecomeKeyNotification, window), (app, NSApplication.didHideNotification, nil),
            (app, NSApplication.didUnhideNotification, nil), (app, Notification.Name.NSProcessInfoPowerStateDidChange, nil),
            (app, ProcessInfo.thermalStateDidChangeNotification, nil), (app, Motion.reduceMotionDidChange, nil),
            (app, Motion.speedDidChange, nil),
            (workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, nil),
        ]
        names.append((app, NSWindow.willCloseNotification, window))
        names += [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                  NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification].map { (workspace, $0, nil) }
        observers = names.map { center, name, object in
            (center, center.addObserver(forName: name, object: object, queue: .main) { [weak self] note in
                let name = note.name
                // main-proof: the observer runs on the main queue (queue: .main)
                MainActor.assumeIsolated { self?.note(name) }
            })
        }
    }

    private func note(_ name: Notification.Name) {
        switch name {
        // A closed window keeps its views: hand the shared player back now, not when the view goes.
        case NSWindow.willCloseNotification: return detach()
        // A window brought to the front shows: play now; the next samples rest it again if needed.
        case NSWindow.didBecomeMainNotification, NSWindow.didBecomeKeyNotification: coverage.reset()
        case NSWorkspace.screensDidSleepNotification: screensAsleep = true
        case NSWorkspace.screensDidWakeNotification: screensAsleep = false
        case NSWorkspace.sessionDidResignActiveNotification: sessionInactive = true
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionInactive = false
        default: break
        }
        update()
    }
}

/// The looping players behind every video wallpaper, one per file, shared by every window that
/// shows it. A player runs while any of its windows wants it and pauses when none does. When none
/// of its windows can even be seen (hidden, covered, the screens asleep) for ``releaseAfter``, it
/// drops its items, which frees the decoder and its frame buffers, and picks up where it was when
/// one is seen again: hours behind other windows cost no video memory.
@MainActor
public final class BackdropVideoPlayers {
    public static let shared = BackdropVideoPlayers()

    private struct Entry {
        let player: AVQueuePlayer
        /// Nil while released.
        var looper: AVPlayerLooper?
        var viewers: Set<ObjectIdentifier>
        var playing: Set<ObjectIdentifier>
        /// The viewers someone could see now.
        var seen: Set<ObjectIdentifier>
        /// Where a released player picks up.
        var resumeAt: CMTime = .zero
        /// A restored item still to be sought to ``resumeAt``, and the wait for it to be ready.
        var pendingRestore = false
        var restoring: NSKeyValueObservation?
        let release: DemandTimer
    }

    private var entries: [URL: Entry] = [:]

    /// How long a player no one can see keeps its decoder.
    public var releaseAfter: Duration = .seconds(60)

    private let clock: any Clock<Duration>

    /// `clock` times ``releaseAfter`` (tests step a manual one).
    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// Players alive now (tests).
    public var count: Int { entries.count }

    /// Whether `url`'s player has given back its decoder (tests).
    public func isReleased(_ url: URL) -> Bool { entries[url].map { $0.looper == nil } ?? false }

    /// Whether `url`'s restored player is still waiting to seek back to its frame (tests).
    public func isRestoring(_ url: URL) -> Bool { entries[url]?.pendingRestore == true }

    func attach(_ url: URL, viewer: ObjectIdentifier) -> AVQueuePlayer {
        if var entry = entries[url] {
            entry.viewers.insert(viewer)
            entries[url] = entry
            return entry.player
        }
        let player = AVQueuePlayer()
        player.isMuted = true
        player.volume = 0
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .advance
        entries[url] = Entry(player: player, looper: Self.looper(url, player), viewers: [viewer], playing: [], seen: [],
                             release: DemandTimer(owner: "backdrop-video-release", clock: clock))
        return player
    }

    func detach(_ url: URL, viewer: ObjectIdentifier) {
        guard var entry = entries[url] else { return }
        entry.viewers.remove(viewer)
        entry.playing.remove(viewer)
        entry.seen.remove(viewer)
        guard entry.viewers.isEmpty else {
            entries[url] = entry
            return apply(url)
        }
        // Torn down in idlesse's order: pause, stop looping, then drop the items.
        entry.release.cancel()
        entry.restoring = nil
        entry.player.pause()
        entry.looper?.disableLooping()
        entry.player.removeAllItems()
        entries[url] = nil
    }

    func setPlaying(_ plays: Bool, seen: Bool = true, _ url: URL, viewer: ObjectIdentifier) {
        guard var entry = entries[url], entry.viewers.contains(viewer) else { return }
        if plays { entry.playing.insert(viewer) } else { entry.playing.remove(viewer) }
        if seen { entry.seen.insert(viewer) } else { entry.seen.remove(viewer) }
        entries[url] = entry
        apply(url)
    }

    /// Gives back `url`'s decoder now if no one can see it (the release timer's work; tests).
    func releaseIfUnseen(_ url: URL) {
        guard var entry = entries[url], entry.playing.isEmpty, entry.seen.isEmpty, let looper = entry.looper else { return }
        entry.resumeAt = entry.player.currentTime()
        entry.pendingRestore = false
        entry.restoring = nil
        entry.player.pause()
        looper.disableLooping()
        entry.player.removeAllItems()
        entry.looper = nil
        entries[url] = entry
    }

    private func apply(_ url: URL) {
        guard var entry = entries[url] else { return }
        if entry.seen.isEmpty, entry.looper != nil {
            // The minute counts from when the last viewer went out of sight, not from each update.
            if !entry.release.isScheduled {
                entry.release.schedule(after: releaseAfter) { @MainActor [weak self] in self?.releaseIfUnseen(url) }
            }
        } else {
            entry.release.cancel()
        }
        if entry.looper == nil, !entry.seen.isEmpty || !entry.playing.isEmpty {
            // Seen again: new items, at the exact frame it held once the first is ready (a seek
            // sent before then can be dropped, or undone by the looper).
            entry.looper = Self.looper(url, entry.player)
            entry.pendingRestore = true
            // Stored before observing: an item already ready reports inline, on this turn.
            entries[url] = entry
            let resumeAt = entry.resumeAt
            let observation = entry.player.observe(\.currentItem?.status, options: [.initial, .new]) { [weak self] player, _ in
                guard player.currentItem?.status == .readyToPlay else { return }
                // AVFoundation may report from its own threads: inline on main, a hop otherwise.
                MainDelivery().run {
                    guard let self, let entry = self.entries[url], entry.pendingRestore else { return }
                    self.entries[url]?.pendingRestore = false
                    self.entries[url]?.restoring = nil
                    entry.player.seek(to: resumeAt, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
            // Kept only while the seek is still to come (an inline report has already done it).
            if entries[url]?.pendingRestore == true { entries[url]?.restoring = observation }
            entry = entries[url] ?? entry
        }
        if entry.playing.isEmpty {
            if entry.player.rate != 0 { entry.player.pause() }
        } else if entry.player.rate == 0 {
            entry.player.play()
        }
    }

    /// A muted, looping item for `url` on `player`, with a short forward buffer.
    private static func looper(_ url: URL, _ player: AVQueuePlayer) -> AVPlayerLooper {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 0.5
        return AVPlayerLooper(player: player, templateItem: item)
    }
}
