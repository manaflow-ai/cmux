public import AppKit
import CmuxNextCompat

/// What one occlusion decision reads about a window (``WindowOcclusionRule``), so the rule is a
/// pure function over values and tests describe windows without a screen.
public nonisolated struct WindowOcclusionFacts: Equatable, Sendable {
    public var id: ObjectIdentifier
    /// The frame in screen coordinates.
    public var frame: CGRect
    /// `NSWindow.level`'s raw value.
    public var level: Int
    /// `NSWindow.isVisible`: ordered in (a minimized window is not).
    public var isVisible: Bool
    public var isMiniaturized: Bool
    /// AppKit's answer (``WindowDrawPolicy/isOnScreen(_:)``): `occlusionState` contains `.visible`.
    /// False on another Space, minimized, in a hidden app, or covered by another app's windows.
    public var systemVisible: Bool
    /// Key or main.
    public var isActive: Bool
    /// It can become key or main.
    public var canBecomeActive: Bool
    /// It hides what is under it: fully opaque, takes mouse events, and is opaque or paints an
    /// opaque background. A glass window (non-opaque, translucent background) does not.
    public var paintsOpaque: Bool
    /// A child window (`parentWindow` set): never judged, as Chrome's checker skips them.
    public var isChild: Bool

    public init(id: ObjectIdentifier, frame: CGRect, level: Int = 0, isVisible: Bool = true, isMiniaturized: Bool = false,
                systemVisible: Bool = true, isActive: Bool = false, canBecomeActive: Bool = true, paintsOpaque: Bool = true,
                isChild: Bool = false) {
        self.id = id
        self.frame = frame
        self.level = level
        self.isVisible = isVisible
        self.isMiniaturized = isMiniaturized
        self.systemVisible = systemVisible
        self.isActive = isActive
        self.canBecomeActive = canBecomeActive
        self.paintsOpaque = paintsOpaque
        self.isChild = isChild
    }
}

/// Whether a window is off screen (Chrome's `Visibility::OCCLUDED`): AppKit says it is not visible
/// (minimized, another Space, a hidden app, covered by other apps' windows), the displays sleep, or
/// one of the app's own windows in front of it covers it.
///
/// AppKit does not report a window covered by a window of the same app, so this copies the manual
/// check of Chrome's `WebContentsOcclusionCheckerMac`
/// (content/app_shim_remote_cocoa/web_contents_occlusion_checker_mac.mm, `-isWindowOccluded:`):
/// a single opaque window in front whose frame contains the window's frame covers it (no region
/// union: the transparent rounded corners of two side-by-side windows can show what is under
/// them). A window that moves or resizes covers nothing until it stops, and the active window is
/// never covered by an inactive one at the same or a lower level, even when `orderedWindows` lags
/// behind the window server.
public nonisolated struct WindowOcclusionRule: Sendable {
    /// The displays sleep (`NSWorkspace.screensDidSleepNotification`): every window is off screen.
    public var displaysAsleep: Bool
    /// The window being moved or live-resized now: it covers nothing.
    public var moving: ObjectIdentifier?

    public init(displaysAsleep: Bool = false, moving: ObjectIdentifier? = nil) {
        self.displaysAsleep = displaysAsleep
        self.moving = moving
    }

    /// Whether `window` is off screen, given the app's windows `frontToBack`
    /// (`NSApplication.orderedWindows`).
    ///
    /// - Parameters:
    ///   - window: The window to judge.
    ///   - frontToBack: The app's windows, front first; `window` among them.
    /// - Returns: True when nothing of it can be seen.
    public func isOccluded(_ window: WindowOcclusionFacts, frontToBack: [WindowOcclusionFacts]) -> Bool {
        if displaysAsleep || !window.systemVisible { return true }
        var seenWindow = false
        for next in frontToBack where next.isVisible {
            if next.id == window.id {
                if window.isActive || !window.canBecomeActive { break }
                // `orderedWindows` can lag behind a window that became active: an active window
                // later in the list may still be in front.
                seenWindow = true
                continue
            }
            if next.id == moving { continue }
            if seenWindow, !next.isActive || next.level < window.level { continue }
            if window.isActive, !next.isActive, next.level <= window.level { continue }
            guard next.systemVisible, next.paintsOpaque else { continue }
            if next.frame.contains(window.frame) { return true }
        }
        return false
    }
}

/// Tells its owner when each of the app's tracked windows goes off screen and comes back
/// (``WindowOcclusionRule``), from window events only: it never polls `occlusionState`.
///
/// The events are Chrome's checker's: AppKit's occlusion changes, a move or live resize starting
/// and ending, a window closing, a window becoming or resigning main (Chrome added these for Cmd-`
/// cycling, which skips `orderWindow:relativeTo:`), fullscreen transitions (whose spurious
/// occlusion changes are ignored for the transitioning window) and the displays sleeping or
/// waking. Chrome also swizzles `-[NSWindow orderWindow:relativeTo:]` to see reorders; cmux does
/// not swizzle AppKit, and a reorder that covers a window changes which window is main, which
/// the main notifications report. As in Chrome, events coalesce into one pass on a later main
/// turn (`performSelector:afterDelay:0`), so the owner's reaction never runs inside a window
/// notification.
///
/// ```swift
/// let checker = WindowOcclusionChecker(windows: { controllers.compactMap(\.window) })
/// checker.onChange = { window, offScreen in cache.windowDidChangeOnScreen(window, offScreen: offScreen) }
/// checker.start()
/// ```
@MainActor public final class WindowOcclusionChecker {
    /// A tracked window went off screen (true) or came back (false). A closing window reports false.
    public var onChange: ((ObjectIdentifier, Bool) -> Void)?
    /// Passes run (tests prove there is no polling).
    public private(set) var passes = 0

    private let windows: @MainActor () -> [NSWindow]
    private let orderedWindows: @MainActor () -> [NSWindow]
    private let facts: @MainActor (NSWindow) -> WindowOcclusionFacts
    /// Occluded windows draw in this launch (``WindowDrawPolicy/drawsWhenOccluded``): none is off screen.
    private let drawsWhenOccluded: Bool
    private let center: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private var rule = WindowOcclusionRule()
    private var offScreen: Set<ObjectIdentifier> = []
    private weak var fullscreenTransition: NSWindow?
    private var observations: [MainActorObservation] = []
    private var scheduled: Task<Void, Never>?

    /// Makes a checker of the windows `windows` returns (the ones whose content counts as hidden
    /// while they are off screen).
    ///
    /// - Parameters:
    ///   - windows: The tracked windows.
    ///   - orderedWindows: The app's windows front to back, the candidates that cover them.
    ///   - facts: Reads a window's facts (a seam for tests: a fake draw policy).
    ///   - drawsWhenOccluded: Automation launches keep occluded windows drawing, and so on screen here.
    ///   - center: Window notifications.
    ///   - workspaceCenter: The displays' sleep and wake.
    public init(windows: @escaping @MainActor () -> [NSWindow],
                orderedWindows: @escaping @MainActor () -> [NSWindow] = { NSApp?.orderedWindows ?? [] },
                facts: @escaping @MainActor (NSWindow) -> WindowOcclusionFacts = WindowDrawPolicy.occlusionFacts(of:),
                drawsWhenOccluded: Bool = WindowDrawPolicy.drawsWhenOccluded,
                center: NotificationCenter = .default,
                workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.windows = windows
        self.orderedWindows = orderedWindows
        self.facts = facts
        self.drawsWhenOccluded = drawsWhenOccluded
        self.center = center
        self.workspaceCenter = workspaceCenter
    }

    /// Observes the window events and runs a first pass on a later turn.
    public func start() {
        guard observations.isEmpty else { return }
        let readWindow: @MainActor (Notification) -> NSWindow? = { $0.object as? NSWindow }
        func on(_ name: Notification.Name, _ handler: @escaping @MainActor (NSWindow) -> Void) {
            observations.append(MainActorObservation(name, center: center, read: readWindow) { window in
                if let window { handler(window) }
            })
        }
        on(NSWindow.willMoveNotification) { [weak self] in self?.movingStarted($0) }
        on(NSWindow.willStartLiveResizeNotification) { [weak self] in self?.movingStarted($0) }
        on(NSWindow.didMoveNotification) { [weak self] in self?.movingEnded($0) }
        on(NSWindow.didEndLiveResizeNotification) { [weak self] in self?.movingEnded($0) }
        on(NSWindow.willCloseNotification) { [weak self] in self?.windowWillClose($0) }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didResignMainNotification] {
            on(name) { [weak self] in self?.windowChanged($0) }
        }
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            on(name) { [weak self] window in self?.fullscreenTransition = window }
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            on(name) { [weak self] _ in
                self?.fullscreenTransition = nil
                self?.schedule()
            }
        }
        observations.append(MainActorObservation(NSWorkspace.screensDidSleepNotification, center: workspaceCenter) { [weak self] in
            self?.rule.displaysAsleep = true
            self?.schedule()
        })
        observations.append(MainActorObservation(NSWorkspace.screensDidWakeNotification, center: workspaceCenter) { [weak self] in
            self?.rule.displaysAsleep = false
            self?.schedule()
        })
        schedule()
    }

    /// Stops observing; every window it reported off screen is reported back on screen.
    public func stop() {
        observations.removeAll()
        scheduled?.cancel()
        scheduled = nil
        let reported = offScreen
        offScreen.removeAll()
        for id in reported { onChange?(id, false) }
    }

    /// Whether `window` was last reported off screen.
    public func isOffScreen(_ window: NSWindow) -> Bool { offScreen.contains(ObjectIdentifier(window)) }

    /// Judges every tracked window now and reports the ones whose state changed.
    public func update() {
        scheduled?.cancel()
        scheduled = nil
        passes += 1
        let ordered = orderedWindows().map(facts)
        var tracked: Set<ObjectIdentifier> = []
        for window in windows() {
            let id = ObjectIdentifier(window)
            tracked.insert(id)
            // macOS sends spurious occlusion changes during a fullscreen transition (crbug.com/1081229).
            if window === fullscreenTransition { continue }
            let current = facts(window)
            set(id, offScreen: judges(current) && rule.isOccluded(current, frontToBack: ordered))
        }
        for id in offScreen.subtracting(tracked) { set(id, offScreen: false) }
    }

    // MARK: Events

    /// A window that is not ordered in and not minimized is the window's own hidden state, and a
    /// child window is never judged; both count as on screen here, as in Chrome's pass.
    private func judges(_ facts: WindowOcclusionFacts) -> Bool {
        guard !drawsWhenOccluded, !facts.isChild else { return false }
        return facts.isVisible || facts.isMiniaturized
    }

    private func tracks(_ window: NSWindow) -> Bool { windows().contains { $0 === window } }

    private func movingStarted(_ window: NSWindow) {
        guard tracks(window) else { return }
        rule.moving = ObjectIdentifier(window)
        schedule()
    }

    /// A programmatic move sends no `willMove`, so every end schedules a pass.
    private func movingEnded(_ window: NSWindow) {
        if rule.moving == ObjectIdentifier(window) { rule.moving = nil }
        if tracks(window) { schedule() }
    }

    private func windowChanged(_ window: NSWindow) {
        if tracks(window) { schedule() }
    }

    /// A closing window may cover others; it no longer counts as off screen itself.
    private func windowWillClose(_ window: NSWindow) {
        set(ObjectIdentifier(window), offScreen: false)
        if window.parentWindow == nil { schedule() }
    }

    private func schedule() {
        guard scheduled == nil else { return }
        scheduled = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }

    private func set(_ id: ObjectIdentifier, offScreen value: Bool) {
        guard value ? offScreen.insert(id).inserted : offScreen.remove(id) != nil else { return }
        onChange?(id, value)
    }
}
