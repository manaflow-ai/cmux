import AppKit

@MainActor
enum SettingsWindowPresenter {
    static let windowID = "settings"
    static let windowIdentifier = "cmux.settings"
    static let minimumSize = NSSize(width: 820, height: 540)
    static let defaultContentSize = NSSize(width: 980, height: 680)
    private static let visibleAreaInset: CGFloat = 18

    /// Builds the cmux-owned Settings window. Registered deterministically by the
    /// app composition root (`AppDelegate.configure`) so the presenter stays
    /// view-agnostic and is ready before any `settings.open`. The passed
    /// `onWindowWillClose` is wired to ``didCloseWindow()`` so the presenter drops
    /// its reference and the window deallocates on close.
    private static var makeWindowController:
        (@MainActor (@escaping @MainActor () -> Void) -> CmuxHostedWindowController)?
    private static var parentWindowProvider: (@MainActor () -> NSWindow?)?
    /// The single live Settings window controller, or `nil` when Settings is
    /// closed. Closing destroys the controller (and its window), so reopening
    /// builds a fresh one — there is no hidden window kept alive for reuse.
    private static var windowController: CmuxHostedWindowController?
    private static var pendingNavigationTarget: SettingsNavigationTarget?
    private static var pendingContentNavigationTarget: SettingsNavigationTarget?
    private static var shouldOpenWhenConfigured = false
#if DEBUG
    private static var focusHandlerForTests: (@MainActor (NSWindow) -> Void)?
#endif

    static func configure(
        makeWindowController: @escaping @MainActor (@escaping @MainActor () -> Void) -> CmuxHostedWindowController,
        parentWindowProvider: @escaping @MainActor () -> NSWindow? = { nil }
    ) {
        self.makeWindowController = makeWindowController
        self.parentWindowProvider = parentWindowProvider
        if shouldOpenWhenConfigured {
            shouldOpenWhenConfigured = false
            openNewWindow()
        }
    }

    static func show(
        navigationTarget: SettingsNavigationTarget? = nil,
        openWindowOverride: (@MainActor () -> Void)? = nil
    ) {
#if DEBUG
        cmuxDebugLog("settings.window.show path=hostedWindow")
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

        if let window = currentWindow() {
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

        // Fresh window: keep the pending navigation target set so the newly
        // created `SettingsWindowRoot` consumes it on appear.
        openNewWindow()
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
        guard let window = currentWindow() else { return }
        focus(window)
    }

#if DEBUG
    /// DEBUG-only: the NSWindow the presenter currently tracks as the Settings
    /// window. `nil` when Settings is closed.
    static var trackedSettingsWindowForDebug: NSWindow? { windowController?.window }

    static func resetForTests() {
        makeWindowController = nil
        parentWindowProvider = nil
        windowController = nil
        pendingNavigationTarget = nil
        pendingContentNavigationTarget = nil
        shouldOpenWhenConfigured = false
        focusHandlerForTests = nil
    }

    static func setFocusHandlerForTests(_ handler: @escaping @MainActor (NSWindow) -> Void) {
        focusHandlerForTests = handler
    }

    /// Runs the real focus/clamp/peer-level ordering on a test-provided window so
    /// the peer-not-child invariant (issue #5081) and visible-area clamping stay
    /// covered without injecting a full hosted controller.
    static func performFocusForTests(_ window: NSWindow, parentWindowProvider: @escaping @MainActor () -> NSWindow? = { nil }) {
        self.parentWindowProvider = parentWindowProvider
        performFocus(window)
    }
#endif

    private static func openNewWindow() {
        guard let makeWindowController else {
            shouldOpenWhenConfigured = true
            return
        }
        let controller = makeWindowController(didCloseWindow)
        windowController = controller
        guard let window = controller.window else { return }
        focus(window)
    }

    /// Called from the controller's `windowWillClose`: drop the reference so the
    /// controller and its window deallocate and leave `NSApp.windows`.
    private static func didCloseWindow() {
        windowController = nil
    }

    private static func currentWindow() -> NSWindow? {
        windowController?.window
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
