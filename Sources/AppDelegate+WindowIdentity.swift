import AppKit
import Foundation

@MainActor
extension AppDelegate {
    func mainWindow(for windowId: UUID) -> NSWindow? {
        windowForMainWindowId(windowId)
    }

    func windowForMainWindowId(_ windowId: UUID) -> NSWindow? {
        if let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }) {
            guard let window = context.window,
                  !hasCommittedMainWindowClose(window) else {
                return nil
            }
            return window
        }
        guard let route = recoverableMainWindowRoute(windowId: windowId),
              let window = route.window,
              NSApp.windows.contains(where: { $0 === window }),
              mainWindowId(from: window) == windowId,
              !hasCommittedMainWindowClose(window) else {
            return nil
        }
        return window
    }

    func mainWindowForClose(windowId: UUID) -> NSWindow? {
        if let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }),
           let window = context.window,
           !hasCommittedMainWindowClose(window) {
            return window
        }
        guard let route = recoverableMainWindowRoute(windowId: windowId),
              let window = route.window,
              NSApp.windows.contains(where: { $0 === window }),
              mainWindowId(from: window) == windowId,
              !hasCommittedMainWindowClose(window) else {
            return nil
        }
        return window
    }

    func startupPrimaryWindowIdForInitialMainWindow() -> UUID? {
        guard !didAttemptStartupSessionRestore else { return nil }
        guard !didHandleExplicitOpenIntentAtStartup else { return nil }
        return startupSessionSnapshot?.windows.first?.windowId
    }

    func availableWindowIdForNewMainWindow(preferredWindowId: UUID?) -> UUID? {
        guard let preferredWindowId else { return nil }
        guard !mainWindowContexts.values.contains(where: { $0.windowId == preferredWindowId }) else { return nil }
        guard recoverableMainWindowRoute(windowId: preferredWindowId) == nil else { return nil }
        return preferredWindowId
    }

    func refreshWindowTitlesAcrossMainWindows() {
        var seenManagers = Set<ObjectIdentifier>()
        for context in mainWindowContexts.values {
            let identifier = ObjectIdentifier(context.tabManager)
            guard seenManagers.insert(identifier).inserted else { continue }
            context.tabManager.refreshWindowTitle()
        }
    }
}
