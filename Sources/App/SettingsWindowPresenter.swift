import AppKit

@MainActor
enum SettingsWindowPresenter {
    static let windowID = "settings"
    static let windowIdentifier = "cmux.settings"
    static let minimumSize = NSSize(width: 820, height: 540)
    private static let visibleAreaInset: CGFloat = 18

    private static var openWindow: (@MainActor () -> Void)?
    private static var parentWindowProvider: (@MainActor () -> NSWindow?)?
    private static weak var settingsWindow: NSWindow?
    private static var pendingNavigationTarget: SettingsNavigationTarget?
    private static var pendingContentNavigationTarget: SettingsNavigationTarget?
    private static var shouldOpenWhenConfigured = false
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
        openWindow()
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
        guard let screen = window.screen ?? NSScreen.main else { return }
        var frame = window.frame
        let originalFrame = frame
        let visibleFrame = screen.visibleFrame
        let minimumFrameSize = NSSize(
            width: max(window.minSize.width, window.contentMinSize.width),
            height: max(window.minSize.height, window.contentMinSize.height)
        )
        let maxVisibleSize = NSSize(
            width: max(minimumFrameSize.width, visibleFrame.width - 2 * visibleAreaInset),
            height: max(minimumFrameSize.height, visibleFrame.height - 2 * visibleAreaInset)
        )
        frame.size.width = min(frame.size.width, maxVisibleSize.width)
        frame.size.height = min(frame.size.height, maxVisibleSize.height)
        let minX = visibleFrame.minX + visibleAreaInset
        let minY = visibleFrame.minY + visibleAreaInset
        let maxX = max(minX, visibleFrame.maxX - visibleAreaInset - frame.width)
        let maxY = max(minY, visibleFrame.maxY - visibleAreaInset - frame.height)
        frame.origin = NSPoint(
            x: min(max(frame.origin.x, minX), maxX),
            y: min(max(frame.origin.y, minY), maxY)
        )

        guard frame != originalFrame else { return }
        window.setFrame(frame, display: true)
    }
}
