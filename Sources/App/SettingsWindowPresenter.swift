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
    private static weak var observedParentWindow: NSWindow?
    private static weak var observedSettingsWindow: NSWindow?
    private static var parentCloseObserver: NSObjectProtocol?
    private static var pendingNavigationTarget: SettingsNavigationTarget?
    private static var pendingContentNavigationTarget: SettingsNavigationTarget?
    private static var shouldOpenWhenConfigured = false

    static func configure(
        openWindow: @escaping @MainActor () -> Void,
        parentWindowProvider: @escaping @MainActor () -> NSWindow? = { nil }
    ) {
        self.openWindow = openWindow
        self.parentWindowProvider = parentWindowProvider
        if let settingsWindow {
            attachToPreferredParent(settingsWindow)
        }
        if shouldOpenWhenConfigured {
            shouldOpenWhenConfigured = false
            openWindow()
        }
    }

    static func configure(window: NSWindow) {
        settingsWindow = window
        window.identifier = NSUserInterfaceItemIdentifier(windowIdentifier)
        window.isRestorable = false
        window.minSize = minimumSize
        window.contentMinSize = minimumSize
        clampToVisibleAreaIfNeeded(window)
        attachToPreferredParent(window)
        Task { @MainActor in
            guard settingsWindow === window else { return }
            focus(window)
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
            pendingNavigationTarget = nil
            pendingContentNavigationTarget = nil
            focus(window)
            if let navigationTarget {
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
        if let settingsWindow {
            detachFromCurrentParent(settingsWindow)
        } else {
            removeParentCloseObserver()
        }
        openWindow = nil
        parentWindowProvider = nil
        settingsWindow = nil
        pendingNavigationTarget = nil
        pendingContentNavigationTarget = nil
        shouldOpenWhenConfigured = false
    }
#endif

    private static func existingWindow() -> NSWindow? {
        if let settingsWindow, settingsWindow.isVisible || settingsWindow.isMiniaturized {
            return settingsWindow
        }
        return NSApp.windows.first {
            $0.identifier?.rawValue == windowIdentifier && ($0.isVisible || $0.isMiniaturized)
        }
    }

    private static func focus(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        clampToVisibleAreaIfNeeded(window)
        if let parentWindow = attachToPreferredParent(window) {
            orderParentBehindSettings(parentWindow)
        }
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    @discardableResult
    private static func attachToPreferredParent(_ window: NSWindow) -> NSWindow? {
        guard let parentWindow = parentWindowProvider?(),
              parentWindow !== window else {
            detachFromCurrentParent(window)
            return nil
        }

        if window.parent !== parentWindow {
            detachFromCurrentParent(window)
            parentWindow.addChildWindow(window, ordered: .above)
        }
        observeParentWillClose(parentWindow, settingsWindow: window)
        return parentWindow
    }

    private static func detachFromCurrentParent(_ window: NSWindow) {
        removeParentCloseObserver()
        guard let parentWindow = window.parent else { return }
        parentWindow.removeChildWindow(window)
    }

    private static func observeParentWillClose(_ parentWindow: NSWindow, settingsWindow: NSWindow) {
        guard observedParentWindow !== parentWindow || observedSettingsWindow !== settingsWindow else {
            return
        }

        removeParentCloseObserver()
        observedParentWindow = parentWindow
        observedSettingsWindow = settingsWindow
        // Run synchronously for normal AppKit window-close notifications so
        // Settings detaches before AppKit orders out child windows.
        parentCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: parentWindow,
            queue: nil
        ) { [weak parentWindow, weak settingsWindow] _ in
            guard Thread.isMainThread else {
                assertionFailure("NSWindow.willCloseNotification should be delivered on the main thread")
                return
            }
            MainActor.assumeIsolated {
                detachFromClosingParent(parentWindow: parentWindow, settingsWindow: settingsWindow)
            }
        }
    }

    private static func detachFromClosingParent(parentWindow: NSWindow?, settingsWindow: NSWindow?) {
        guard let settingsWindow, settingsWindow.parent === parentWindow else {
            removeParentCloseObserver()
            return
        }
        detachFromCurrentParent(settingsWindow)
    }

    private static func removeParentCloseObserver() {
        if let parentCloseObserver {
            NotificationCenter.default.removeObserver(parentCloseObserver)
        }
        parentCloseObserver = nil
        observedParentWindow = nil
        observedSettingsWindow = nil
    }

    private static func orderParentBehindSettings(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.orderFront(nil)
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
