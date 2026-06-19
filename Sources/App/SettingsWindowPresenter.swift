import AppKit
import CmuxTestSupport

@MainActor
struct SettingsWindowPresenter {
    static let windowID = "settings"
    static let windowIdentifier = "cmux.settings"
    static let minimumSize = NSSize(width: 820, height: 540)
    private static let visibleAreaInset: CGFloat = 18
    private static let sharedPresenter = SettingsWindowPresenter()

    private final class State: NSObject {
        var openWindow: (@MainActor () -> Void)?
        var parentWindowProvider: (@MainActor () -> NSWindow?)?
        weak var settingsWindow: NSWindow?
        var pendingNavigationTarget: SettingsNavigationTarget?
        var pendingContentNavigationTarget: SettingsNavigationTarget?
        var shouldOpenWhenConfigured = false
        var shouldFocusWhenConfigured = false
        var isOpeningSettingsWindow = false

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

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
            settingsWindow = nil
            isOpeningSettingsWindow = false
        }
    }

    private let state: State

    init() {
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
            state.isOpeningSettingsWindow = true
            openWindow()
        }
    }

    static func configure(window: NSWindow) {
        sharedPresenter.configure(window: window)
    }

    func configure(window: NSWindow) {
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
            state.shouldFocusWhenConfigured = true
            state.isOpeningSettingsWindow = true
            openWindowOverride()
            return
        }

        guard let openWindow = state.openWindow else {
            state.shouldOpenWhenConfigured = true
            state.shouldFocusWhenConfigured = true
            return
        }
        state.shouldFocusWhenConfigured = true
        state.isOpeningSettingsWindow = true
        openWindow()
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
            $0.identifier?.rawValue == Self.windowIdentifier &&
            ($0.isVisible || $0.isMiniaturized)
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
        guard let screen = window.screen ?? NSScreen.main else { return }
        var frame = window.frame
        let originalFrame = frame
        let visibleFrame = screen.visibleFrame
        let minimumFrameSize = NSSize(
            width: max(window.minSize.width, window.contentMinSize.width),
            height: max(window.minSize.height, window.contentMinSize.height)
        )
        let maxVisibleSize = NSSize(
            width: max(minimumFrameSize.width, visibleFrame.width - 2 * Self.visibleAreaInset),
            height: max(minimumFrameSize.height, visibleFrame.height - 2 * Self.visibleAreaInset)
        )
        frame.size.width = min(frame.size.width, maxVisibleSize.width)
        frame.size.height = min(frame.size.height, maxVisibleSize.height)
        let minX = visibleFrame.minX + Self.visibleAreaInset
        let minY = visibleFrame.minY + Self.visibleAreaInset
        let maxX = max(minX, visibleFrame.maxX - Self.visibleAreaInset - frame.width)
        let maxY = max(minY, visibleFrame.maxY - Self.visibleAreaInset - frame.height)
        frame.origin = NSPoint(
            x: min(max(frame.origin.x, minX), maxX),
            y: min(max(frame.origin.y, minY), maxY)
        )

        guard frame != originalFrame else { return }
        window.setFrame(frame, display: true)
    }
}
