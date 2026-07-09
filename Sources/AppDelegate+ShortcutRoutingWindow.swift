import AppKit
import CmuxFoundation

extension AppDelegate {
    var shortcutRoutingKeyWindow: NSWindow? {
#if DEBUG
        if let window = debugShortcutRoutingFocusedWindowOverrideForTesting.window {
            if debugShortcutRoutingFocusedWindowOverrideForTesting.shouldCaptureFocusedWindow {
                return window
            }
            if contextForMainWindow(window) != nil
                || isMainTerminalWindow(window)
                || AuxiliaryWindowRegistry.default.shouldOwnCloseShortcut(window.identifier?.rawValue) {
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

    func contextForMainWindow(_ window: NSWindow?) -> RegisteredMainWindow? {
        guard let window else { return nil }
        return contextForMainTerminalWindow(window)
    }

    func activeTabManagerForCommands(preferredWindow: NSWindow? = nil) -> TabManager? {
        environment.mainWindowRouter.activeTabManagerForCommands(preferredWindow: preferredWindow)
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

}
