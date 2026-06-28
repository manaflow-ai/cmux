import AppKit
import CmuxNotifications
import CmuxWindowing
import Foundation

@MainActor
extension AppDelegate {
    func mainWindow(for windowId: UUID) -> NSWindow? {
        windowForMainWindowId(windowId)
    }

    func windowForMainWindowId(_ windowId: UUID) -> NSWindow? {
        // Resolve the live handle from `windowCoordinator` directly (the owner of
        // window↔id identity). This must NOT route through
        // `registeredMainWindow(for:)`, which itself falls back to this method —
        // that would recurse. The coordinator lookup replaces the old "registered
        // context with a live `.window`" read.
        if let window = windowCoordinator.window(for: WindowID(windowId)) {
            return window
        }
        let expectedIdentifier = MainTerminalWindowIdentifier(forWindowId: windowId).expectedIdentifier
        return NSApp.windows.first(where: { $0.identifier?.rawValue == expectedIdentifier })
    }

    func startupPrimaryWindowIdForInitialMainWindow() -> UUID? {
        guard !didAttemptStartupSessionRestore else { return nil }
        guard !didHandleExplicitOpenIntentAtStartup else { return nil }
        return startupSessionSnapshot?.windows.first?.windowId
    }

    func availableWindowIdForNewMainWindow(preferredWindowId: UUID?) -> UUID? {
        guard let preferredWindowId else { return nil }
        guard !registeredMainWindows.contains(where: { $0.windowId == preferredWindowId }) else { return nil }
        return preferredWindowId
    }

    func refreshWindowTitlesAcrossMainWindows() {
        var seenManagers = Set<ObjectIdentifier>()
        for context in registeredMainWindows {
            let identifier = ObjectIdentifier(context.tabManager)
            guard seenManagers.insert(identifier).inserted else { continue }
            context.tabManager.refreshWindowTitle()
        }
    }
}
