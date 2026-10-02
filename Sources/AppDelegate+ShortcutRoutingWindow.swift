import AppKit

extension AppDelegate {
    var shortcutRoutingKeyWindow: NSWindow? {
#if DEBUG
        if let window = debugShortcutRoutingFocusedWindowOverrideForTesting.window {
            if debugShortcutRoutingFocusedWindowOverrideForTesting.shouldCaptureFocusedWindow {
                return window
            }
            if contextForMainWindow(window) != nil
                || isMainTerminalWindow(window)
                || cmuxWindowShouldOwnCloseShortcut(window) {
                return window
            }
            debugShortcutRoutingFocusedWindowOverrideForTesting.window = nil
        }
#endif
        return NSApp.keyWindow
    }

    var shortcutRoutingActiveWindow: NSWindow? {
        shortcutRoutingKeyWindow ?? NSApp.mainWindow
    }

    func shortcutRoutingFirstResponder(preferredWindow: NSWindow? = nil) -> NSResponder? {
        preferredWindow?.firstResponder
            ?? shortcutRoutingKeyWindow?.firstResponder
            ?? NSApp.mainWindow?.firstResponder
    }

    func contextForMainWindow(_ window: NSWindow?) -> MainWindowContext? {
        guard let window else { return nil }
        return contextForMainTerminalWindow(window)
    }

    func activeTabManagerForCommands(preferredWindow: NSWindow? = nil) -> TabManager? {
        if let preferredWindow {
            return senderRelativeMainWindowContext(for: preferredWindow)?.tabManager
        }
        if let context = contextForMainWindow(shortcutRoutingKeyWindow) {
            return context.tabManager
        }
        if let context = contextForMainWindow(NSApp.mainWindow) {
            return context.tabManager
        }
        if let activeManager = tabManager,
           let activeContext = liveMainWindowContext(for: activeManager) {
            return activeContext.tabManager
        }
        return mainWindowContexts.values.first { context in
            resolvedWindow(for: context) != nil
        }?.tabManager
    }

    /// Resolves an in-window action from the exact AppKit window that emitted
    /// it. Sender-relative actions must never fall through to the process-wide
    /// key/main/active-manager chain: a consumed first-mouse event can leave
    /// those globals pointing at a different window.
    func senderRelativeMainWindowContext(for window: NSWindow) -> MainWindowContext? {
        guard let context = mainWindowContexts[ObjectIdentifier(window)],
              context.window === window else {
            return nil
        }
        if let windowId = mainWindowId(from: window),
           context.windowId != windowId {
            return nil
        }
        return context
    }

    func repairFocusedTerminalKeyboardRoutingIfNeeded(
        window: NSWindow,
        event: NSEvent
    ) {
        let firstResponderOverride: NSResponder?
#if DEBUG
        firstResponderOverride = debugShortcutRoutingFocusedWindowOverrideForTesting.keyRepairFirstResponder
#else
        firstResponderOverride = nil
#endif
        repairFocusedTerminalKeyboardRoutingIfNeeded(
            window: window,
            event: event,
            firstResponderOverride: firstResponderOverride
        )
    }

    private func liveMainWindowContext(for tabManager: TabManager) -> MainWindowContext? {
        for context in Array(mainWindowContexts.values) where context.tabManager === tabManager {
            if resolvedWindow(for: context) != nil {
                return context
            }
        }
        return nil
    }
}
