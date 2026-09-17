import AppKit
import ObjectiveC

/// A key routed before portal mount retains its pane as the release owner.
/// Weak identities prevent a close or surface replacement from retargeting it.
@MainActor
private final class CloudMountKeyOwners {
    static var associationKey: UInt8 = 0
    final class Owner {
        weak var view: GhosttyNSView?
        weak var surface: TerminalSurface?
        init(_ view: GhosttyNSView) { self.view = view; surface = view.terminalSurface }
    }
    var keys: [UInt16: Owner] = [:]
}

extension AppDelegate {
    func captureCloudMountKeyRelease(window: NSWindow, event: NSEvent, view: GhosttyNSView) {
        let owners: CloudMountKeyOwners
        if let existing = objc_getAssociatedObject(window, &CloudMountKeyOwners.associationKey) as? CloudMountKeyOwners {
            owners = existing
        } else {
            owners = CloudMountKeyOwners()
            objc_setAssociatedObject(window, &CloudMountKeyOwners.associationKey, owners, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        owners.keys[event.keyCode] = CloudMountKeyOwners.Owner(view)
    }

    func forwardCloudMountKeyRelease(window: NSWindow, event: NSEvent) -> Bool {
        guard event.type == .keyUp,
              let owners = objc_getAssociatedObject(window, &CloudMountKeyOwners.associationKey) as? CloudMountKeyOwners,
              let owner = owners.keys.removeValue(forKey: event.keyCode) else { return false }
        if let view = owner.view, let surface = owner.surface, view.terminalSurface === surface {
            view.keyUp(with: event)
        }
        return true
    }

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

    @discardableResult
    func repairFocusedTerminalKeyboardRoutingIfNeeded(
        window: NSWindow,
        event: NSEvent
    ) -> Bool {
        let firstResponderOverride: NSResponder?
#if DEBUG
        firstResponderOverride = debugShortcutRoutingFocusedWindowOverrideForTesting.keyRepairFirstResponder
#else
        firstResponderOverride = nil
#endif
        return repairFocusedTerminalKeyboardRoutingIfNeeded(
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
