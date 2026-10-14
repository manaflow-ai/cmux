public import AppKit
public import AVFoundation

/// A video wallpaper behind a window's content (cx-14vdf): the file loops, muted, through
/// `AVPlayerLayer`, filling the window as the art does. It plays only while someone can see it
/// and the Mac can afford it, and holds its frame otherwise:
///
/// - the window is visible (not occluded, minimized or hidden with the app), the screens are
///   awake and the session is the active one;
/// - not in Low Power Mode, and the thermal state is below serious;
/// - looping motion is allowed (`Motion.animatesLoops`: Reduce Motion or animation speed "off"
///   holds the first frame, which the art view below already shows as the poster).
///
/// Every window showing one file shares one decoder (``BackdropVideoPlayers``), as idlesse found
/// one decoder per display doubled the video decoder's load; a 0.5 s forward buffer keeps 4K
/// frames out of memory, and the layer stays clear until its first frame is ready, so a new
/// window never flashes black.
public final class BackdropVideoView: NSView {
    /// The file shown, nil when the wallpaper is no video.
    public private(set) var url: URL?
    /// The layer the shared player draws into.
    public let playerLayer = AVPlayerLayer()
    /// Tests: pins Reduce Motion, Low Power Mode or visibility for this view instead of the system's.
    public var reduceMotionOverride: Bool? { didSet { update() } }
    public var lowPowerOverride: Bool? { didSet { update() } }
    public var visibleOverride: Bool? { didSet { update() } }
    private let players: BackdropVideoPlayers
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var readyObservation: NSKeyValueObservation?
    private var screensAsleep = false
    private var sessionInactive = false

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
            // main-proof: AVPlayerLayer reports readiness on the main thread
            MainActor.assumeIsolated { self?.showFrames(ready) }
        }
        update()
    }

    private func detach() {
        readyObservation = nil
        guard let url, playerLayer.player != nil else { return }
        players.detach(url, viewer: ObjectIdentifier(self))
        playerLayer.player = nil
        playerLayer.opacity = 0
    }

    /// Whether the shared player runs for this view now.
    public var isPlaying: Bool { (playerLayer.player?.rate ?? 0) > 0 }

    /// Whether this view asks its player to run: shown, seen, and allowed to move.
    public var wantsPlayback: Bool {
        guard url != nil, !isHidden, let window else { return false }
        let visible = visibleOverride ?? (window.occlusionState.contains(.visible) && !window.isMiniaturized && !NSApp.isHidden)
        let lowPower = lowPowerOverride ?? ProcessInfo.processInfo.isLowPowerModeEnabled
        let reduced = reduceMotionOverride ?? !Motion.animatesLoops
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        return visible && !screensAsleep && !sessionInactive && !lowPower && !hot && !reduced
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

    private func showFrames(_ ready: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.opacity = ready ? 1 : 0
        CATransaction.commit()
    }

    private func update() {
        guard let url, playerLayer.player != nil else { return }
        players.setPlaying(wantsPlayback, url, viewer: ObjectIdentifier(self))
    }

    private func observe() {
        let app = NotificationCenter.default, workspace = NSWorkspace.shared.notificationCenter
        var names: [(NotificationCenter, Notification.Name, AnyObject?)] = [
            (app, NSWindow.didChangeOcclusionStateNotification, window), (app, NSWindow.didMiniaturizeNotification, window),
            (app, NSWindow.didDeminiaturizeNotification, window), (app, NSApplication.didHideNotification, nil),
            (app, NSApplication.didUnhideNotification, nil), (app, Notification.Name.NSProcessInfoPowerStateDidChange, nil),
            (app, ProcessInfo.thermalStateDidChangeNotification, nil), (app, Motion.reduceMotionDidChange, nil),
            (workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, nil),
        ]
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
/// shows it. A player runs while any of its windows wants it and pauses when none does.
@MainActor
public final class BackdropVideoPlayers {
    public static let shared = BackdropVideoPlayers()

    private struct Entry {
        let player: AVQueuePlayer
        let looper: AVPlayerLooper
        var viewers: Set<ObjectIdentifier>
        var playing: Set<ObjectIdentifier>
    }

    private var entries: [URL: Entry] = [:]

    public init() {}

    /// Players alive now (tests).
    public var count: Int { entries.count }

    func attach(_ url: URL, viewer: ObjectIdentifier) -> AVQueuePlayer {
        if var entry = entries[url] {
            entry.viewers.insert(viewer)
            entries[url] = entry
            return entry.player
        }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 0.5
        let player = AVQueuePlayer()
        player.isMuted = true
        player.volume = 0
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .advance
        entries[url] = Entry(player: player, looper: AVPlayerLooper(player: player, templateItem: item), viewers: [viewer], playing: [])
        return player
    }

    func detach(_ url: URL, viewer: ObjectIdentifier) {
        guard var entry = entries[url] else { return }
        entry.viewers.remove(viewer)
        entry.playing.remove(viewer)
        guard entry.viewers.isEmpty else {
            entries[url] = entry
            return apply(entry)
        }
        // Torn down in idlesse's order: pause, stop looping, then drop the items.
        entry.player.pause()
        entry.looper.disableLooping()
        entry.player.removeAllItems()
        entries[url] = nil
    }

    func setPlaying(_ plays: Bool, _ url: URL, viewer: ObjectIdentifier) {
        guard var entry = entries[url], entry.viewers.contains(viewer) else { return }
        if plays { entry.playing.insert(viewer) } else { entry.playing.remove(viewer) }
        entries[url] = entry
        apply(entry)
    }

    private func apply(_ entry: Entry) {
        if entry.playing.isEmpty {
            if entry.player.rate != 0 { entry.player.pause() }
        } else if entry.player.rate == 0 {
            entry.player.play()
        }
    }
}
