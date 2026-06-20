import AppKit
import CmuxTestSupport
import os

@MainActor
struct SettingsWindowPresenter {
    static let windowID = "settings"
    static let windowIdentifier = "cmux.settings"
    static let minimumSize = NSSize(width: 820, height: 540)
    private static let visibleAreaInset: CGFloat = 18
    private static let sharedPresenter = SettingsWindowPresenter()
    /// Release-safe diagnostics so intermittent "Settings won't open" reports
    /// (https://github.com/manaflow-ai/cmux/issues/5770) become attributable
    /// from `log show --predicate 'subsystem == "com.cmuxterm.app" && category == "Settings"'`.
    private nonisolated static let log = Logger(subsystem: "com.cmuxterm.app", category: "Settings")
    /// Number of times to re-request the SwiftUI window when an open request
    /// produces no window. The single `Window` scene's `openWindow(id:)` can
    /// silently no-op mid-teardown, which is the "nothing happens" symptom.
    static let maxOpenAttempts = 2

    private let openVerificationDelay: Duration

    private final class State: NSObject {
        var openWindow: (@MainActor () -> Void)?
        var parentWindowProvider: (@MainActor () -> NSWindow?)?
        weak var settingsWindow: NSWindow?
        var pendingNavigationTarget: SettingsNavigationTarget?
        var pendingContentNavigationTarget: SettingsNavigationTarget?
        var shouldOpenWhenConfigured = false
        var shouldFocusWhenConfigured = false
        var isOpeningSettingsWindow = false
        var openVerificationTask: Task<Void, Never>?

        deinit {
            openVerificationTask?.cancel()
            NotificationCenter.default.removeObserver(self)
        }

        @MainActor
        @objc
        func settingsWindowWillClose(_ notification: Notification) {
            guard
                let window = notification.object as? NSWindow,
                settingsWindow === window
            else { return }
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: window
            )
            // Ordered-out live windows can still be re-fronted through the weak
            // reference; closed windows must not be rediscovered from NSApp.
            window.identifier = nil
            settingsWindow = nil
            isOpeningSettingsWindow = false
            openVerificationTask?.cancel()
            openVerificationTask = nil
        }
    }

    private let state: State

    init(openVerificationDelay: Duration = .milliseconds(500)) {
        self.openVerificationDelay = openVerificationDelay
        state = State()
    }

    static func configure(
        openWindow: @escaping @MainActor () -> Void,
        parentWindowProvider: @escaping @MainActor () -> NSWindow? = { nil }
    ) {
        sharedPresenter.configure(
            openWindow: openWindow,
            parentWindowProvider: parentWindowProvider
        )
    }

    func configure(
        openWindow: @escaping @MainActor () -> Void,
        parentWindowProvider: @escaping @MainActor () -> NSWindow? = { nil }
    ) {
        state.openWindow = openWindow
        state.parentWindowProvider = parentWindowProvider
        if state.shouldOpenWhenConfigured {
            state.shouldOpenWhenConfigured = false
            requestOpen(using: openWindow)
        }
    }

    static func configure(window: NSWindow) {
        sharedPresenter.configure(window: window)
    }

    func configure(window: NSWindow) {
        // Window materialization is the success signal for issue #5770's
        // silent-open retry path; a slow SwiftUI scene must not be retried
        // after it has produced a real window.
        cancelOpenVerification()
        let isNewSettingsWindow = state.settingsWindow !== window
        let shouldFocusAfterConfiguration = isNewSettingsWindow && state.shouldFocusWhenConfigured
        if shouldFocusAfterConfiguration {
            state.shouldFocusWhenConfigured = false
        }
        state.settingsWindow = window
        state.isOpeningSettingsWindow = false
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = Self.minimumSize
        window.contentMinSize = Self.minimumSize
        window.adoptCmuxPeerWindowLevel()
        clampToVisibleAreaIfNeeded(window)
        if isNewSettingsWindow {
            observeClose(of: window)
        }
        if shouldFocusAfterConfiguration {
            Task { @MainActor in
                guard state.settingsWindow === window else { return }
                focus(window)
            }
        }
    }

    static func show(
        navigationTarget: SettingsNavigationTarget? = nil,
        openWindowOverride: (@MainActor () -> Void)? = nil
    ) {
        sharedPresenter.show(
            navigationTarget: navigationTarget,
            openWindowOverride: openWindowOverride
        )
    }

    func show(
        navigationTarget: SettingsNavigationTarget? = nil,
        openWindowOverride: (@MainActor () -> Void)? = nil
    ) {
#if DEBUG
        cmuxDebugLog("settings.window.show path=swiftuiWindow")
        _ = UITestCaptureSink().mutateJSONObjectIfConfigured(
            envKey: "CMUX_UI_TEST_SETTINGS_OPEN_CAPTURE_PATH"
        ) { payload in
            payload["opened"] = true
            payload["target"] = navigationTarget?.rawValue ?? ""
            payload["used_open_window_override"] = openWindowOverride != nil
        }
#endif
        state.pendingNavigationTarget = navigationTarget
        state.pendingContentNavigationTarget = navigationTarget

        if let window = existingWindow() {
            recordMaterializedWindowIfNeeded(window)
            Self.logExistingWindowState(window)
            let shouldDeferNavigation = window.isMiniaturized
            if !shouldDeferNavigation {
                state.pendingNavigationTarget = nil
                state.pendingContentNavigationTarget = nil
            }
            focus(window)
            if let navigationTarget, !shouldDeferNavigation {
                SettingsNavigationRequest.post(navigationTarget)
            }
            return
        }

        if state.isOpeningSettingsWindow {
            state.shouldFocusWhenConfigured = true
            return
        }

        if let openWindowOverride {
            // The override still funnels into SwiftUI's `openWindow(id:)`, which
            // can hit the same mid-teardown no-op, so it gets the same retry/
            // logging recovery as the configured opener (issue #5770).
            Self.log.notice("settings.window.show no existing window; requesting via override")
            requestOpen(using: openWindowOverride)
            return
        }

        guard let openWindow = state.openWindow else {
            state.shouldOpenWhenConfigured = true
            state.shouldFocusWhenConfigured = true
            return
        }
        Self.log.notice("settings.window.show no existing window; requesting new settings window")
        requestOpen(using: openWindow)
    }

    static func consumePendingNavigationTarget() -> SettingsNavigationTarget? {
        sharedPresenter.consumePendingNavigationTarget()
    }

    func consumePendingNavigationTarget() -> SettingsNavigationTarget? {
        let target = state.pendingNavigationTarget
        state.pendingNavigationTarget = nil
        return target
    }

    static func consumePendingContentNavigationTarget() -> SettingsNavigationTarget? {
        sharedPresenter.consumePendingContentNavigationTarget()
    }

    func consumePendingContentNavigationTarget() -> SettingsNavigationTarget? {
        let target = state.pendingContentNavigationTarget
        state.pendingContentNavigationTarget = nil
        return target
    }

    static func refocusIfVisible() {
        sharedPresenter.refocusIfVisible()
    }

    func refocusIfVisible() {
        guard let window = visibleExistingWindow() else { return }
        focus(window)
    }

    private func existingWindow() -> NSWindow? {
        if let settingsWindow = state.settingsWindow {
            return settingsWindow
        }
        return NSApp.windows.first {
            $0.identifier?.rawValue == Self.windowIdentifier
        }
    }

    private func visibleExistingWindow() -> NSWindow? {
        if let settingsWindow = state.settingsWindow,
           settingsWindow.isVisible,
           !settingsWindow.isMiniaturized {
            return settingsWindow
        }
        return NSApp.windows.first {
            $0.identifier?.rawValue == Self.windowIdentifier &&
            $0.isVisible &&
            !$0.isMiniaturized
        }
    }

    /// Re-request the window when the previous request silently produced no
    /// window. `openWindow(id:)` on a single `Window` scene can no-op while the
    /// scene is mid-teardown, and there is no failure callback, so a deferred
    /// check is the only way to notice the lost request (issue #5770 / #4053).
    /// Success is event-driven: `configure(window:)` cancels the pending check
    /// as soon as the scene materializes a window, so the timer below only ever
    /// decides the failure case.
    private func requestOpen(using opener: @escaping @MainActor () -> Void) {
        state.shouldFocusWhenConfigured = true
        state.isOpeningSettingsWindow = true
        opener()
        if state.isOpeningSettingsWindow {
            scheduleOpenVerification(attempt: 1, opener: opener)
        }
    }

    private func scheduleOpenVerification(
        attempt: Int,
        opener: @escaping @MainActor () -> Void
    ) {
        guard state.openVerificationTask == nil else { return }
        state.openVerificationTask = Task { @MainActor in
            do {
                // Intentional bounded deadline; `configure(window:)` cancels it on success.
                try await ContinuousClock().sleep(for: openVerificationDelay)
            } catch {
                return
            }
            _ = resolveOpenVerification(attempt: attempt, opener: opener)
        }
    }

    @discardableResult
    func resolveOpenVerification(
        attempt: Int,
        opener: @escaping @MainActor () -> Void
    ) -> SettingsWindowOpenOutcome {
        cancelOpenVerification()
        let existingWindow = existingWindow()
        let outcome = Self.openOutcome(windowExists: existingWindow != nil, attempt: attempt)
        switch outcome {
        case .materialized:
            state.isOpeningSettingsWindow = false
            if let existingWindow {
                recordMaterializedWindowIfNeeded(existingWindow)
            }
        case .retry:
            state.isOpeningSettingsWindow = true
            Self.log.error(
                "settings.window.open no window after attempt \(attempt, privacy: .public); retrying"
            )
            opener()
            if state.isOpeningSettingsWindow {
                scheduleOpenVerification(attempt: attempt + 1, opener: opener)
            }
        case .giveUp:
            state.isOpeningSettingsWindow = false
            Self.log.error(
                "settings.window.open gave up after \(attempt, privacy: .public) attempts; no window materialized"
            )
        }
        return outcome
    }

    private func recordMaterializedWindowIfNeeded(_ window: NSWindow) {
        cancelOpenVerification()
        state.isOpeningSettingsWindow = false
        if state.settingsWindow !== window {
            state.settingsWindow = window
            observeClose(of: window)
        }
    }

    private func cancelOpenVerification() {
        state.openVerificationTask?.cancel()
        state.openVerificationTask = nil
    }

    static func openOutcome(windowExists: Bool, attempt: Int) -> SettingsWindowOpenOutcome {
        if windowExists {
            return .materialized
        }
        return attempt < maxOpenAttempts ? .retry : .giveUp
    }

    private static func logExistingWindowState(_ window: NSWindow) {
        log.notice(
            """
            settings.window.show found existing window \
            visible=\(window.isVisible, privacy: .public) \
            miniaturized=\(window.isMiniaturized, privacy: .public) \
            onActiveSpace=\(window.isOnActiveSpace, privacy: .public) \
            offAllScreens=\(window.screen == nil, privacy: .public) \
            frame=\(NSStringFromRect(window.frame), privacy: .public)
            """
        )
    }

    private func focus(_ window: NSWindow) {
        performFocus(window)
    }

    private func performFocus(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.adoptCmuxPeerWindowLevel()
        clampToVisibleAreaIfNeeded(window)
        // Surface the preferred main window first so Settings opens layered
        // above it — the standard "Settings in front of its app" presentation
        // a global hotkey or app activation expects. We do this by ordering
        // both windows front *as peers*, never via `addChildWindow`: a child
        // window is pinned above its parent forever and can never recede when
        // the user clicks the main window (the bug in
        // https://github.com/manaflow-ai/cmux/issues/5081). One-time front
        // ordering gives the same initial layering while leaving normal
        // click-to-raise window ordering fully intact afterwards.
        if let parentWindow = state.parentWindowProvider?(), parentWindow !== window {
            if parentWindow.isMiniaturized {
                parentWindow.deminiaturize(nil)
            }
            parentWindow.orderFront(nil)
        }
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func observeClose(of window: NSWindow) {
        NotificationCenter.default.removeObserver(
            state,
            name: NSWindow.willCloseNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            state,
            selector: #selector(State.settingsWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    private func clampToVisibleAreaIfNeeded(_ window: NSWindow) {
        let screens = NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let fallbackVisibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        guard let visibleFrame = Self.targetVisibleFrame(
            windowFrame: window.frame,
            screens: screens,
            mouseLocation: NSEvent.mouseLocation,
            fallbackVisibleFrame: fallbackVisibleFrame
        ) else { return }

        let minimumFrameSize = NSSize(
            width: max(window.minSize.width, window.contentMinSize.width),
            height: max(window.minSize.height, window.contentMinSize.height)
        )
        let originalFrame = window.frame
        let clamped = Self.clampedFrame(
            originalFrame,
            minimumSize: minimumFrameSize,
            into: visibleFrame,
            inset: Self.visibleAreaInset
        )
        guard clamped != originalFrame else { return }

        let wasOffAllScreens = window.screen == nil
        window.setFrame(clamped, display: true)
        if wasOffAllScreens {
            Self.log.notice(
                """
                settings.window.clamp recovered an offscreen frame onto a visible screen \
                from=\(NSStringFromRect(originalFrame), privacy: .public) \
                to=\(NSStringFromRect(clamped), privacy: .public)
                """
            )
        }
    }

    /// Pure selection of the visible-screen frame the settings window should be
    /// clamped into. When the window's saved frame is off every active screen
    /// (e.g. restored onto a now-disconnected display in a multi-monitor setup)
    /// it recovers onto the screen under the cursor, then the main/first screen.
    /// Cursor hit-testing uses each screen's *full* frame: `visibleFrame`
    /// excludes the menu bar and Dock strips, and the cursor sits exactly there
    /// when Settings is opened from the menu bar, which would misroute the
    /// recovery to the main screen. The returned rect is always a visible
    /// frame. Factored out so multi-monitor recovery is unit-testable.
    static func targetVisibleFrame(
        windowFrame: NSRect,
        screens: [(frame: NSRect, visibleFrame: NSRect)],
        mouseLocation: NSPoint?,
        fallbackVisibleFrame: NSRect?
    ) -> NSRect? {
        guard !screens.isEmpty else { return fallbackVisibleFrame }

        // Prefer the screen the window already overlaps the most so a window
        // that is mostly visible stays where the user put it.
        var bestFrame: NSRect?
        var bestArea: CGFloat = 0
        for screen in screens {
            let intersection = screen.visibleFrame.intersection(windowFrame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestFrame = screen.visibleFrame
            }
        }
        if let bestFrame, bestArea > 0 {
            return bestFrame
        }

        // The window is off every active screen. Recover onto the screen under
        // the cursor when possible so Settings appears where the user is looking.
        if let mouseLocation,
           let mouseScreen = screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return mouseScreen.visibleFrame
        }
        return fallbackVisibleFrame ?? screens.first?.visibleFrame
    }

    /// Pure clamp geometry: fit `frame` within `visibleFrame` (honoring `inset`
    /// and a minimum size). Factored out of `clampToVisibleAreaIfNeeded` so the
    /// geometry is unit-testable independent of `NSWindow`/`NSScreen`.
    static func clampedFrame(
        _ frame: NSRect,
        minimumSize: NSSize,
        into visibleFrame: NSRect,
        inset: CGFloat
    ) -> NSRect {
        var result = frame
        let maxVisibleSize = NSSize(
            width: max(minimumSize.width, visibleFrame.width - 2 * inset),
            height: max(minimumSize.height, visibleFrame.height - 2 * inset)
        )
        result.size.width = min(result.size.width, maxVisibleSize.width)
        result.size.height = min(result.size.height, maxVisibleSize.height)
        let minX = visibleFrame.minX + inset
        let minY = visibleFrame.minY + inset
        let maxX = max(minX, visibleFrame.maxX - inset - result.width)
        let maxY = max(minY, visibleFrame.maxY - inset - result.height)
        result.origin = NSPoint(
            x: min(max(result.origin.x, minX), maxX),
            y: min(max(result.origin.y, minY), maxY)
        )
        return result
    }
}
