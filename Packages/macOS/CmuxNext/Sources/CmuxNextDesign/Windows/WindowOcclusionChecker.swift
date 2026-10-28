public import AppKit
import CmuxNextCompat
public import CmuxNextWakeups

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
    /// False on another Space, minimized, or covered by another app's windows. A hidden app's
    /// windows are ordered out instead (``WindowOcclusionRule/appHidden``).
    public var systemVisible: Bool
    /// Key or main.
    public var isActive: Bool
    /// It can become key or main.
    public var canBecomeActive: Bool
    /// It hides what is under it: fully opaque, takes mouse events, and is opaque or paints an
    /// opaque background. A glass window (non-opaque, translucent background) does not.
    public var paintsOpaque: Bool
    /// Its `parentWindow` chain, nearest first. A window never covers its own ancestors: a Chromium
    /// page window is a child of its cmux window, ordered above it and key while the page has focus.
    public var ancestors: [ObjectIdentifier]
    /// A child window (`parentWindow` set): never judged, as Chrome's checker skips them.
    public var isChild: Bool { !ancestors.isEmpty }

    public init(id: ObjectIdentifier, frame: CGRect, level: Int = 0, isVisible: Bool = true, isMiniaturized: Bool = false,
                systemVisible: Bool = true, isActive: Bool = false, canBecomeActive: Bool = true, paintsOpaque: Bool = true,
                ancestors: [ObjectIdentifier] = []) {
        self.id = id
        self.frame = frame
        self.level = level
        self.isVisible = isVisible
        self.isMiniaturized = isMiniaturized
        self.systemVisible = systemVisible
        self.isActive = isActive
        self.canBecomeActive = canBecomeActive
        self.paintsOpaque = paintsOpaque
        self.ancestors = ancestors
    }
}

/// Whether a window is off screen (Chrome's `Visibility::OCCLUDED`): AppKit says it is not visible
/// (minimized, another Space, covered by other apps' windows), the app is hidden, the displays
/// sleep, or one of the app's own windows in front of it covers it.
///
/// AppKit does not report a window covered by a window of the same app, so this copies the manual
/// check of Chrome's `WebContentsOcclusionCheckerMac`
/// (content/app_shim_remote_cocoa/web_contents_occlusion_checker_mac.mm, `-isWindowOccluded:`):
/// a single opaque window in front whose frame contains the window's frame covers it (no region
/// union: the transparent rounded corners of two side-by-side windows can show what is under
/// them). A window that moves or resizes covers nothing until it stops, a window never covers its
/// own ancestors, and the active window is never covered by an inactive one at the same or a lower
/// level, even when `orderedWindows` lags behind the window server.
public nonisolated struct WindowOcclusionRule: Sendable {
    /// The displays sleep (`NSWorkspace.screensDidSleepNotification`): every window is off screen.
    public var displaysAsleep: Bool
    /// The app is hidden (Cmd-H, `NSApplication.isHidden`): every window is off screen.
    public var appHidden: Bool
    /// The window being moved or live-resized now: it covers nothing.
    public var moving: ObjectIdentifier?

    public init(displaysAsleep: Bool = false, appHidden: Bool = false, moving: ObjectIdentifier? = nil) {
        self.displaysAsleep = displaysAsleep
        self.appHidden = appHidden
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
        if displaysAsleep || appHidden || !window.systemVisible { return true }
        var seenWindow = false
        for next in frontToBack where next.isVisible {
            if next.id == window.id {
                if window.isActive || !window.canBecomeActive { break }
                // `orderedWindows` can lag behind a window that became active: an active window
                // later in the list may still be in front.
                seenWindow = true
                continue
            }
            if next.id == moving || next.ancestors.contains(window.id) { continue }
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
/// The events are Chrome's checker's, from any of the app's windows, since any of them can cover
/// a tracked one (onboarding, a debug window, a panel): AppKit's occlusion changes, a move or live
/// resize starting and ending, a resize, a window closing, a window becoming or resigning main
/// (Chrome added these for Cmd-` cycling, which skips `orderWindow:relativeTo:`), fullscreen
/// transitions (whose spurious occlusion changes are ignored for the transitioning window), the
/// app hiding or unhiding, and the displays sleeping or waking. Chrome also swizzles
/// `-[NSWindow orderWindow:relativeTo:]` to see reorders; cmux does not swizzle AppKit: its one
/// owner of window ordering, `WindowActivation`, reports each order it makes
/// (``windowsDidReorder()``). As in Chrome, events coalesce into one pass on a later main turn
/// (`performSelector:afterDelay:0`), so the owner's reaction never runs inside a window
/// notification: one `visible` task on the app's scheduler (a window coming back on screen resumes
/// its frames). As in Chrome, a child window's notices start no pass (`-windowCanTriggerOcclusionUpdates:`):
/// it is never judged and moves with its parent. The notices whose handler needs no sender come through
/// one ``AppEvents`` fan-out, the displays' sleep through the app's workspace one.
///
/// ```swift
/// let checker = WindowOcclusionChecker(windows: { controllers.compactMap(\.window) },
///                                      workspaceEvents: services.workspaceEvents, mainWork: services.mainWork)
/// checker.onChange = { window, offScreen in cache.windowDidChangeOnScreen(window, offScreen: offScreen) }
/// checker.onClose = { window in cache.offScreenWindowDidClose(window) }
/// checker.start()
/// ```
@MainActor public final class WindowOcclusionChecker {
    /// A tracked window went off screen (true) or came back (false).
    public var onChange: ((ObjectIdentifier, Bool) -> Void)?
    /// A window last reported off screen closed or stopped being tracked. It is dropped without a
    /// report that it came back, so nothing it shows is shown again while it goes away.
    public var onClose: ((ObjectIdentifier) -> Void)?
    /// Passes run (tests prove there is no polling).
    public private(set) var passes = 0

    private let windows: @MainActor () -> [NSWindow]
    private let orderedWindows: @MainActor () -> [NSWindow]
    private let facts: @MainActor (NSWindow) -> WindowOcclusionFacts
    private let isAppHidden: @MainActor () -> Bool
    /// Occluded windows draw in this launch (``WindowDrawPolicy/drawsWhenOccluded``): none is off screen.
    private let drawsWhenOccluded: Bool
    private let center: NotificationCenter
    /// The sender-free window and app notices of ``center``, one observer per name.
    private let notices: AppEvents
    /// The displays' sleep and wake (NSWorkspace's center).
    private let workspaceEvents: AppEvents
    private let mainWork: MainWorkScheduler
    private var rule = WindowOcclusionRule()
    private var offScreen: Set<ObjectIdentifier> = []
    private weak var fullscreenTransition: NSWindow?
    /// The notices whose handler reads the posting window.
    private var observations: [MainActorObservation] = []
    private var subscriptions: [EventSubscription] = []
    /// A pass is posted and not run yet; ``update()`` and ``stop()`` clear it, so the posted pass does nothing.
    private var passPending = false

    /// Makes a checker of the windows `windows` returns (the ones whose content counts as hidden
    /// while they are off screen).
    ///
    /// - Parameters:
    ///   - windows: The tracked windows.
    ///   - orderedWindows: The app's windows front to back, the candidates that cover them.
    ///   - facts: Reads a window's facts (a seam for tests: a fake draw policy).
    ///   - isAppHidden: Whether the app is hidden now.
    ///   - drawsWhenOccluded: Automation launches keep occluded windows drawing, and so on screen here.
    ///   - center: Window and application notifications.
    ///   - workspaceEvents: The displays' sleep and wake: the app's events of NSWorkspace's center.
    ///   - mainWork: The app's main-thread scheduler, where the coalesced pass is posted.
    public init(windows: @escaping @MainActor () -> [NSWindow],
                orderedWindows: @escaping @MainActor () -> [NSWindow] = { NSApp?.orderedWindows ?? [] },
                facts: @escaping @MainActor (NSWindow) -> WindowOcclusionFacts = WindowDrawPolicy.occlusionFacts(of:),
                isAppHidden: @escaping @MainActor () -> Bool = { NSApp?.isHidden ?? false },
                drawsWhenOccluded: Bool = WindowDrawPolicy.drawsWhenOccluded,
                center: NotificationCenter = .default,
                workspaceEvents: AppEvents, mainWork: MainWorkScheduler) {
        self.windows = windows
        self.orderedWindows = orderedWindows
        self.facts = facts
        self.isAppHidden = isAppHidden
        self.drawsWhenOccluded = drawsWhenOccluded
        self.center = center
        notices = AppEvents(center: center)
        self.workspaceEvents = workspaceEvents
        self.mainWork = mainWork
    }

    /// Observes the window events and runs a first pass on a later turn.
    public func start() {
        guard !isStarted else { return }
        let readWindow: @MainActor (Notification) -> NSWindow? = { $0.object as? NSWindow }
        // These handlers read the posting window, which an AppEvents call does not carry.
        func on(_ name: Notification.Name, _ handler: @escaping @MainActor (NSWindow) -> Void) {
            observations.append(MainActorObservation(name, center: center, read: readWindow) { window in
                if let window { handler(window) }
            })
        }
        on(NSWindow.willMoveNotification) { [weak self] in self?.movingStarted($0) }  // raw-observer-allow: reads the sender
        on(NSWindow.willStartLiveResizeNotification) { [weak self] in self?.movingStarted($0) }  // raw-observer-allow: reads the sender
        on(NSWindow.didMoveNotification) { [weak self] in self?.movingEnded($0) }  // raw-observer-allow: reads the sender
        on(NSWindow.didEndLiveResizeNotification) { [weak self] in self?.movingEnded($0) }  // raw-observer-allow: reads the sender
        // A programmatic or tiling resize; a live resize reports its end instead.
        on(NSWindow.didResizeNotification) { [weak self] window in  // raw-observer-allow: reads the sender
            if !window.inLiveResize, window.parent == nil { self?.schedule() }
        }
        on(NSWindow.willCloseNotification) { [weak self] in self?.windowWillClose($0) }  // raw-observer-allow: reads the sender
        on(NSWindow.willEnterFullScreenNotification) { [weak self] in self?.fullscreenTransition = $0 }  // raw-observer-allow: reads the sender
        on(NSWindow.willExitFullScreenNotification) { [weak self] in self?.fullscreenTransition = $0 }  // raw-observer-allow: reads the sender
        // A child window's own occlusion or main change starts no pass while every tracked window is on screen:
        // a child is never judged and moves with its parent, and a new tab or split orders overlay panels, divider
        // catchers and page windows as children, each pass waiting on the window server for the order (Chrome:
        // `-windowCanTriggerOcclusionUpdates:`, components/remote_cocoa/app_shim/window_occlusion_checker_mac.mm).
        // While one is off screen a child's change may uncover it (an opaque page child of a glass window), and a
        // tracked window that became a child must be reported back on screen (crbug.com/1337390): then it passes.
        let topLevelPass: @MainActor (NSWindow) -> Void = { [weak self] window in
            guard let self, window.parent == nil || !offScreen.isEmpty else { return }
            schedule()
        }
        on(NSWindow.didChangeOcclusionStateNotification, topLevelPass)  // raw-observer-allow: reads the sender
        on(NSWindow.didBecomeMainNotification, topLevelPass)  // raw-observer-allow: reads the sender
        on(NSWindow.didResignMainNotification, topLevelPass)  // raw-observer-allow: reads the sender
        let owner = "WindowOcclusionChecker"
        let pass: @MainActor () -> Void = { [weak self] in self?.schedule() }
        let fullscreenEnded: @MainActor () -> Void = { [weak self] in
            self?.fullscreenTransition = nil
            self?.schedule()
        }
        subscriptions = [
            notices.subscribe(NSWindow.didEnterFullScreenNotification, owner: owner, fullscreenEnded),
            notices.subscribe(NSWindow.didExitFullScreenNotification, owner: owner, fullscreenEnded),
            // Hiding the app orders every window out without an occlusion change of its own.
            notices.subscribe(NSApplication.didHideNotification, owner: owner, pass),
            notices.subscribe(NSApplication.didUnhideNotification, owner: owner, pass),
            workspaceEvents.subscribe(NSWorkspace.screensDidSleepNotification, owner: owner) { [weak self] in self?.displaysSlept(true) },
            workspaceEvents.subscribe(NSWorkspace.screensDidWakeNotification, owner: owner) { [weak self] in self?.displaysSlept(false) },
        ]
        schedule()
    }

    /// Stops observing; every window it reported off screen is reported back on screen.
    public func stop() {
        observations.removeAll()
        subscriptions.forEach { $0.cancel() }
        subscriptions.removeAll()
        passPending = false
        let reported = offScreen
        offScreen.removeAll()
        for id in reported { onChange?(id, false) }
    }

    private var isStarted: Bool { !subscriptions.isEmpty }

    /// Whether `window` was last reported off screen.
    public func isOffScreen(_ window: NSWindow) -> Bool { offScreen.contains(ObjectIdentifier(window)) }

    /// The app ordered a window in, in front or behind (`WindowActivation`), in place of Chrome's
    /// `orderWindow:relativeTo:` swizzle: a window ordered front without becoming key or main
    /// posts nothing else that starts a pass.
    public func windowsDidReorder() {
        guard isStarted else { return }
        schedule()
    }

    /// Judges every tracked window now and reports the ones whose state changed.
    public func update() {
        passPending = false
        passes += 1
        rule.appHidden = isAppHidden()
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
        for id in offScreen.subtracting(tracked) { drop(id) }
    }

    // MARK: Events

    /// A child window is never judged, as in Chrome's pass. A window that is neither ordered in nor
    /// minimized is in its own hidden state and counts as on screen here, unless the app is hidden:
    /// that orders every window out.
    private func judges(_ facts: WindowOcclusionFacts) -> Bool {
        guard !drawsWhenOccluded, !facts.isChild else { return false }
        return facts.isVisible || facts.isMiniaturized || rule.appHidden
    }

    /// A moving top-level window covers nothing until it stops. A child window moves with its parent.
    private func movingStarted(_ window: NSWindow) {
        guard window.parent == nil else { return }
        rule.moving = ObjectIdentifier(window)
        schedule()
    }

    /// A programmatic move sends no `willMove`, so every end schedules a pass.
    private func movingEnded(_ window: NSWindow) {
        if rule.moving == ObjectIdentifier(window) { rule.moving = nil }
        if window.parent == nil { schedule() }
    }

    /// A closing window may cover others. It is dropped, not reported back on screen.
    private func windowWillClose(_ window: NSWindow) {
        drop(ObjectIdentifier(window))
        if window.parent == nil { schedule() }
    }

    private func drop(_ id: ObjectIdentifier) {
        guard offScreen.remove(id) != nil else { return }
        onClose?(id)
    }

    private func displaysSlept(_ asleep: Bool) {
        rule.displaysAsleep = asleep
        schedule()
    }

    private func schedule() {
        guard !passPending else { return }
        passPending = true
        mainWork.post(.visible, owner: "WindowOcclusionChecker.pass") { [weak self] in
            guard let self, passPending else { return }
            update()
        }
    }

    private func set(_ id: ObjectIdentifier, offScreen value: Bool) {
        guard value ? offScreen.insert(id).inserted : offScreen.remove(id) != nil else { return }
        onChange?(id, value)
    }
}
