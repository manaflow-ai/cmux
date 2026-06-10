import AppKit
import os

@MainActor
enum SettingsWindowPresenter {
    static let windowID = "settings"
    static let windowIdentifier = "cmux.settings"
    static let minimumSize = NSSize(width: 820, height: 540)
    private static let visibleAreaInset: CGFloat = 18
    /// Release-safe diagnostics so intermittent "Settings won't open" reports
    /// (https://github.com/manaflow-ai/cmux/issues/5770) become attributable
    /// from `log show --predicate 'subsystem == "com.cmuxterm.app" && category == "Settings"'`.
    private static let log = Logger(subsystem: "com.cmuxterm.app", category: "Settings")
    /// Number of times to re-request the SwiftUI window when an open request
    /// produces no window. The single `Window` scene's `openWindow(id:)` can
    /// silently no-op mid-teardown, which is the "nothing happens" symptom.
    static let maxOpenAttempts = 2

    private static var openWindow: (@MainActor () -> Void)?
    private static var parentWindowProvider: (@MainActor () -> NSWindow?)?
    private static weak var settingsWindow: NSWindow?
    private static var pendingNavigationTarget: SettingsNavigationTarget?
    private static var pendingContentNavigationTarget: SettingsNavigationTarget?
    private static var shouldOpenWhenConfigured = false
    private static var openVerificationInFlight = false
#if DEBUG
    private static var focusHandlerForTests: (@MainActor (NSWindow) -> Void)?
#endif

    static func configure(
        openWindow: @escaping @MainActor () -> Void,
        parentWindowProvider: @escaping @MainActor () -> NSWindow? = { nil }
    ) {
        self.openWindow = openWindow
        self.parentWindowProvider = parentWindowProvider
        if shouldOpenWhenConfigured {
            shouldOpenWhenConfigured = false
            openWindow()
        }
    }

    static func configure(window: NSWindow) {
        let shouldFocusAfterConfiguration = settingsWindow !== window
        settingsWindow = window
        window.identifier = NSUserInterfaceItemIdentifier(windowIdentifier)
        window.isRestorable = false
        window.minSize = minimumSize
        window.contentMinSize = minimumSize
        window.adoptCmuxPeerWindowLevel()
        clampToVisibleAreaIfNeeded(window)
        if shouldFocusAfterConfiguration {
            Task { @MainActor in
                guard settingsWindow === window else { return }
                focus(window)
            }
        }
    }

    static func show(
        navigationTarget: SettingsNavigationTarget? = nil,
        openWindowOverride: (@MainActor () -> Void)? = nil
    ) {
#if DEBUG
        cmuxDebugLog("settings.window.show path=swiftuiWindow")
        _ = CmuxUITestCapture.mutateJSONObjectIfConfigured(
            envKey: "CMUX_UI_TEST_SETTINGS_OPEN_CAPTURE_PATH"
        ) { payload in
            payload["opened"] = true
            payload["target"] = navigationTarget?.rawValue ?? ""
            payload["used_open_window_override"] = openWindowOverride != nil
        }
#endif
        pendingNavigationTarget = navigationTarget
        pendingContentNavigationTarget = navigationTarget

        if let window = existingWindow() {
            logExistingWindowState(window)
            let shouldDeferNavigation = window.isMiniaturized
            if !shouldDeferNavigation {
                pendingNavigationTarget = nil
                pendingContentNavigationTarget = nil
            }
            focus(window)
            if let navigationTarget, !shouldDeferNavigation {
                SettingsNavigationRequest.post(navigationTarget)
            }
            return
        }

        if let openWindowOverride {
            openWindowOverride()
            return
        }

        guard let openWindow else {
            shouldOpenWhenConfigured = true
            return
        }
        log.notice("settings.window.show no existing window; requesting new settings window")
        openWindow()
        scheduleOpenVerification(attempt: 1)
    }

    static func consumePendingNavigationTarget() -> SettingsNavigationTarget? {
        let target = pendingNavigationTarget
        pendingNavigationTarget = nil
        return target
    }

    static func consumePendingContentNavigationTarget() -> SettingsNavigationTarget? {
        let target = pendingContentNavigationTarget
        pendingContentNavigationTarget = nil
        return target
    }

    static func refocusIfVisible() {
        guard let window = existingWindow() else { return }
        focus(window)
    }

#if DEBUG
    static func resetForTests() {
        openWindow = nil
        parentWindowProvider = nil
        settingsWindow = nil
        pendingNavigationTarget = nil
        pendingContentNavigationTarget = nil
        shouldOpenWhenConfigured = false
        openVerificationInFlight = false
        focusHandlerForTests = nil
    }

    static func setFocusHandlerForTests(_ handler: @escaping @MainActor (NSWindow) -> Void) {
        focusHandlerForTests = handler
    }
#endif

    private static func existingWindow() -> NSWindow? {
        // Return the settings window whenever it still exists, even if it
        // is currently ordered out (closed). SwiftUI's single `Window`
        // scene does not destroy the window on close — it just hides it
        // (isVisible == false) — and `openWindow(id:)` then no-ops because
        // the scene still owns that window. So filtering by visibility here
        // made every reopen-after-close fall through to a dead `openWindow`
        // call and the window never came back. Reusing the hidden window
        // lets `show()` re-front it via `makeKeyAndOrderFront`.
        if let settingsWindow {
            return settingsWindow
        }
        return NSApp.windows.first {
            $0.identifier?.rawValue == windowIdentifier
        }
    }

    /// Re-request the window after a short delay when the previous request
    /// produced no window. `openWindow(id:)` on a single `Window` scene can
    /// silently no-op while the scene is mid-teardown; without this the open
    /// request is lost and "nothing happens" (issue #5770 / #4053).
    private static func scheduleOpenVerification(attempt: Int) {
        guard !openVerificationInFlight else { return }
        openVerificationInFlight = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            openVerificationInFlight = false
            switch openOutcome(windowExists: existingWindow() != nil, attempt: attempt) {
            case .materialized:
                return
            case .retry:
                log.error(
                    "settings.window.open no window after attempt \(attempt, privacy: .public); retrying"
                )
                openWindow?()
                scheduleOpenVerification(attempt: attempt + 1)
            case .giveUp:
                log.error(
                    "settings.window.open gave up after \(attempt, privacy: .public) attempts; no window materialized"
                )
            }
        }
    }

    /// Pure recovery policy for a settings-window open request, factored out so
    /// the retry behavior is unit-testable without driving SwiftUI scenes.
    enum OpenOutcome: Equatable {
        case materialized
        case retry
        case giveUp
    }

    static func openOutcome(windowExists: Bool, attempt: Int) -> OpenOutcome {
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

    private static func focus(_ window: NSWindow) {
#if DEBUG
        if let focusHandlerForTests {
            focusHandlerForTests(window)
            return
        }
#endif
        performFocus(window)
    }

    private static func performFocus(_ window: NSWindow) {
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
        if let parentWindow = parentWindowProvider?(), parentWindow !== window {
            if parentWindow.isMiniaturized {
                parentWindow.deminiaturize(nil)
            }
            parentWindow.orderFront(nil)
        }
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private static func clampToVisibleAreaIfNeeded(_ window: NSWindow) {
        let screenVisibleFrames = NSScreen.screens.map(\.visibleFrame)
        let fallbackVisibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        guard let visibleFrame = targetVisibleFrame(
            windowFrame: window.frame,
            screenVisibleFrames: screenVisibleFrames,
            mouseLocation: NSEvent.mouseLocation,
            fallbackVisibleFrame: fallbackVisibleFrame
        ) else { return }

        let minimumFrameSize = NSSize(
            width: max(window.minSize.width, window.contentMinSize.width),
            height: max(window.minSize.height, window.contentMinSize.height)
        )
        let originalFrame = window.frame
        let clamped = clampedFrame(
            originalFrame,
            minimumSize: minimumFrameSize,
            into: visibleFrame,
            inset: visibleAreaInset
        )
        guard clamped != originalFrame else { return }

        let wasOffAllScreens = window.screen == nil
        window.setFrame(clamped, display: true)
        if wasOffAllScreens {
            log.notice(
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
    /// Factored out so multi-monitor recovery is unit-testable.
    static func targetVisibleFrame(
        windowFrame: NSRect,
        screenVisibleFrames: [NSRect],
        mouseLocation: NSPoint?,
        fallbackVisibleFrame: NSRect?
    ) -> NSRect? {
        guard !screenVisibleFrames.isEmpty else { return fallbackVisibleFrame }

        // Prefer the screen the window already overlaps the most so a window
        // that is mostly visible stays where the user put it.
        var bestFrame: NSRect?
        var bestArea: CGFloat = 0
        for visibleFrame in screenVisibleFrames {
            let intersection = visibleFrame.intersection(windowFrame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestFrame = visibleFrame
            }
        }
        if let bestFrame, bestArea > 0 {
            return bestFrame
        }

        // The window is off every active screen. Recover onto the screen under
        // the cursor when possible so Settings appears where the user is looking.
        if let mouseLocation,
           let mouseScreen = screenVisibleFrames.first(where: { $0.contains(mouseLocation) }) {
            return mouseScreen
        }
        return fallbackVisibleFrame ?? screenVisibleFrames.first
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
