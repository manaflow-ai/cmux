import AppKit

@MainActor
enum BrowserNativeSurfaceTracker {
    private static var activeMenuCount = 0

    static var blocksBrowserShortcuts: Bool {
        activeMenuCount > 0
    }

    static func menuDidOpen() {
        activeMenuCount += 1
    }

    static func menuDidClose(closingEvent: NSEvent? = NSApp?.currentEvent) {
        activeMenuCount = max(0, activeMenuCount - 1)
    }

    static func resetForTesting() {
        activeMenuCount = 0
    }
}
