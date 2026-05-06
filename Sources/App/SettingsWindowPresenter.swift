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
    }

    static func show(navigationTarget: SettingsNavigationTarget? = nil) {
#if DEBUG
        cmuxDebugLog("settings.window.show path=swiftuiWindow")
#endif
        pendingNavigationTarget = navigationTarget

        if let window = existingWindow() {
            pendingNavigationTarget = nil
            attachToPreferredParent(window)
            focus(window)
            if let navigationTarget {
                SettingsNavigationRequest.post(navigationTarget)
            }
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

    static func refocusIfVisible() {
        guard let window = existingWindow() else { return }
        attachToPreferredParent(window)
        focus(window)
    }

#if DEBUG
    static func resetForTests() {
        if let settingsWindow {
            detachFromCurrentParent(settingsWindow)
        }
        openWindow = nil
        parentWindowProvider = nil
        settingsWindow = nil
        pendingNavigationTarget = nil
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
        return parentWindow
    }

    private static func detachFromCurrentParent(_ window: NSWindow) {
        guard let parentWindow = window.parent else { return }
        parentWindow.removeChildWindow(window)
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
        let visibleFrame = screen.visibleFrame
        let minX = visibleFrame.minX + visibleAreaInset
        let minY = visibleFrame.minY + visibleAreaInset
        let maxX = max(minX, visibleFrame.maxX - visibleAreaInset - frame.width)
        let maxY = max(minY, visibleFrame.maxY - visibleAreaInset - frame.height)
        let clampedOrigin = NSPoint(
            x: min(max(frame.origin.x, minX), maxX),
            y: min(max(frame.origin.y, minY), maxY)
        )

        guard clampedOrigin != frame.origin else { return }
        frame.origin = clampedOrigin
        window.setFrame(frame, display: true)
    }
}
