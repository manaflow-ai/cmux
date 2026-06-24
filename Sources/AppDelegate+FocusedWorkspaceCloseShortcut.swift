import AppKit

extension AppDelegate {
    func mainWindowContextForFocusedWorkspaceCloseShortcut(event: NSEvent) -> MainWindowContext? {
        if let keyWindow = NSApp.keyWindow,
           let context = contextForMainTerminalWindow(keyWindow) {
            return context
        }

        if let mainWindow = NSApp.mainWindow,
           let context = contextForMainTerminalWindow(mainWindow) {
            return context
        }

        if let context = mainWindowContext(forShortcutEvent: event, debugSource: "shortcut.closeWorkspace") {
            return context
        }

        if shortcutEventHasAddressableWindow(event) {
            if let eventWindow = resolvedShortcutEventWindow(event),
               cmuxWindowShouldOwnCloseShortcut(eventWindow) {
                return preferredMainWindowContextForShortcutRouting(event: event)
            }
            return nil
        }

        return nil
    }

    @discardableResult
    func closeWorkspaceFromFocusedShortcut(event: NSEvent) -> Bool {
        guard let context = mainWindowContextForFocusedWorkspaceCloseShortcut(event: event) else {
            return false
        }

        if let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
        } else {
            activateMainWindowContext(context)
        }

        context.tabManager.closeCurrentWorkspaceWithConfirmation()
        return true
    }
}
