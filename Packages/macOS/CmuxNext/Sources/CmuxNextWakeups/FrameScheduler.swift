public import AppKit
public import QuartzCore

/// What a scheduler needs from a display link (a fake in tests).
@MainActor
public protocol FrameLink: AnyObject {
    var isPaused: Bool { get set }
    func invalidate()
}

extension CADisplayLink: FrameLink {}

/// The one display link of a window (architecture.md 3 and 5): it runs only
/// while at least one ``FrameClient`` is active and pauses itself when the
/// last one goes idle (dropping the link), so an idle window has no frame
/// wakeups.
///
/// Every animation, drag autoscroll, resize settle and per-frame batch in
/// CmuxNext is a client of its window's scheduler; window-less work (the
/// daemon store drain, the control work queue) uses ``app``, bound to the
/// main screen. No other code may create a display link
/// (`scripts/cmux-next/check-concurrency.sh`).
///
/// A display link stops firing while the displays sleep, when its screen
/// goes away, and for some occluded windows, yet clients such as the daemon
/// mirror must keep moving. So while any client is active a one-shot stall
/// deadline runs: when no frame came in time the clients tick anyway, and
/// after repeated stalls the link is rebuilt.
@MainActor
public final class FrameScheduler: NSObject {
    public typealias LinkFactory = @MainActor (FrameScheduler) -> (any FrameLink)?

    /// Longest wait for a frame while clients are active.
    public static let stallTimeout: Duration = .milliseconds(100)
    /// Consecutive stalls after which the link is replaced.
    public static let stallsBeforeRebuild = 3

    /// The scheduler for window-less work, on the main screen.
    public static let app = FrameScheduler(name: "app", host: .screen)

    private static var windows: [ObjectIdentifier: WeakScheduler] = [:]

    /// `window`'s scheduler, created on first use and dropped with the window.
    public static func forWindow(_ window: NSWindow) -> FrameScheduler {
        let key = ObjectIdentifier(window)
        if let scheduler = windows[key]?.value, scheduler.window === window { return scheduler }
        windows = windows.filter { $0.value.value?.window != nil }
        let scheduler = FrameScheduler(name: "window \(window.windowNumber)", host: .window(window))
        windows[key] = WeakScheduler(value: scheduler)
        // The window keeps its scheduler alive.
        objc_setAssociatedObject(window, &FrameScheduler.associationKey, scheduler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        // The link retains its target: break the cycle when the window closes.
        scheduler.closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak scheduler] _ in
            MainActor.assumeIsolated { scheduler?.invalidate() }
        }
        return scheduler
    }

    /// The scheduler of `view`'s window, or ``app`` while it has none.
    public static func forView(_ view: NSView) -> FrameScheduler {
        view.window.map(forWindow) ?? app
    }

    /// Every live scheduler (debug.wakeups).
    public static var all: [FrameScheduler] {
        [app] + windows.values.compactMap(\.value)
    }

    private static var associationKey: UInt8 = 0

    enum Host {
        case screen
        case window(NSWindow)
    }

    public let name: String
    public private(set) weak var window: NSWindow?
    private let isScreenHost: Bool
    private var clients: [ObjectIdentifier: FrameClient] = [:]
    private var link: (any FrameLink)?
    private let makeLinkOverride: LinkFactory?
    private let ledger: WakeupLedger
    private let stall: DemandTimer
    private var stalls = 0
    private var lastTimestamp: CFTimeInterval?
    private var closeObserver: (any NSObjectProtocol)?
    /// Frames delivered since creation (debug).
    public private(set) var frames: UInt64 = 0

    init(name: String, host: Host, clock: any Clock<Duration> = ContinuousClock(), ledger: WakeupLedger = .shared,
         makeLink: LinkFactory? = nil) {
        self.name = name
        switch host {
        case .screen: isScreenHost = true
        case .window(let window):
            isScreenHost = false
            self.window = window
        }
        self.ledger = ledger
        self.makeLinkOverride = makeLink
        stall = DemandTimer(owner: "FrameScheduler.stall", clock: clock, ledger: ledger)
        super.init()
    }

    /// A scheduler with a fake link (tests).
    public static func testing(clock: any Clock<Duration> = ContinuousClock(), ledger: WakeupLedger = .shared,
                               makeLink: @escaping LinkFactory) -> FrameScheduler {
        FrameScheduler(name: "test", host: .screen, clock: clock, ledger: ledger, makeLink: makeLink)
    }

    /// Owners of the clients that are ticking now.
    public var activeClients: [String] {
        clients.values.filter(\.isActive).map(\.owner).sorted()
    }

    public var isRunning: Bool { link.map { !$0.isPaused } ?? false }

    /// A display link exists (only while clients are active).
    public var hasLink: Bool { link != nil }

    // MARK: Clients

    func activate(_ client: FrameClient) {
        clients[ObjectIdentifier(client)] = client
        guard let link = link ?? makeLink() else {
            // No screen (headless launch): tick once on the next turn.
            // task-owner: one hop; the client deactivates or re-arms on its tick
            Task { @MainActor [weak self] in self?.frameDidFire(timestamp: nil) }
            return
        }
        if link.isPaused {
            lastTimestamp = nil
            link.isPaused = false
        }
        armStall()
    }

    func deactivate(_ client: FrameClient) {
        clients[ObjectIdentifier(client)] = nil
        if clients.isEmpty { pause() }
    }

    /// Drops the link while idle: an idle window holds no display link at
    /// all (and no link -> scheduler retain cycle); the next client makes a
    /// new one.
    private func pause() {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
        stall.cancel()
        stalls = 0
    }

    /// Drops the link and every client (the window closed).
    public func invalidate() {
        for client in clients.values { client.detach() }
        clients.removeAll()
        stall.cancel()
        link?.invalidate()
        link = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }

    // MARK: Frames

    private func makeLink() -> (any FrameLink)? {
        let made: (any FrameLink)?
        if let makeLinkOverride {
            made = makeLinkOverride(self)
        } else if !isScreenHost, let window {
            // concurrency-allow: the sanctioned display link (one per window)
            let display = window.displayLink(target: self, selector: #selector(tick(_:)))
            display.add(to: .main, forMode: .common)
            made = display
        } else if let screen = NSScreen.main ?? NSScreen.screens.first {
            // concurrency-allow: the sanctioned display link (window-less work)
            let display = screen.displayLink(target: self, selector: #selector(tick(_:)))
            display.add(to: .main, forMode: .common)
            made = display
        } else {
            made = nil
        }
        link = made
        return made
    }

    @objc private func tick(_ link: CADisplayLink) {
        frameDidFire(timestamp: link.timestamp, refreshInterval: link.targetTimestamp - link.timestamp)
    }

    private func armStall() {
        stall.scheduleIfIdle(after: Self.stallTimeout) { @MainActor [weak self] in self?.frameStalled() }
    }

    private func frameStalled() {
        guard !clients.isEmpty else { return }
        stalls += 1
        if stalls >= Self.stallsBeforeRebuild {
            stalls = 0
            link?.invalidate()
            link = nil
        }
        ledger.record("FrameScheduler.\(name)", reason: "stalled frame")
        deliver(timestamp: nil, refreshInterval: nil)
        guard !clients.isEmpty else { return }
        (link ?? makeLink())?.isPaused = false
        armStall()
    }

    /// One display frame (the link's tick; tests call it directly).
    public func frameDidFire(timestamp: CFTimeInterval? = nil, refreshInterval: Double? = nil) {
        stall.cancel()
        stalls = 0
        deliver(timestamp: timestamp, refreshInterval: refreshInterval)
        if clients.isEmpty { pause() } else { armStall() }
    }

    private func deliver(timestamp: CFTimeInterval?, refreshInterval: Double?) {
        frames &+= 1
        let now = timestamp ?? CACurrentMediaTime()
        let elapsed = lastTimestamp.map { now - $0 } ?? (1.0 / 60.0)
        lastTimestamp = now
        let tick = FrameTick(timestamp: now, elapsed: min(max(elapsed, 1.0 / 240.0), 1.0 / 30.0),
                             rawElapsed: elapsed, refreshInterval: refreshInterval)
        // Clients activated during this frame tick next frame.
        for client in clients.values where client.isActive {
            ledger.record(client.owner, reason: "frame")
            if !client.fire(tick) { clients[ObjectIdentifier(client)] = nil }
        }
    }

    private struct WeakScheduler {
        weak var value: FrameScheduler?
    }
}
