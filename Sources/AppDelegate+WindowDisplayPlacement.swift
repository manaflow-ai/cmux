import AppKit
import CmuxWindowing

// MARK: - Window display placement (`window.display` / `window.displays`)

extension AppDelegate {
    /// A connected display, surfaced by the `window.displays` control command and
    /// the `cmux window display --list` CLI so callers can discover screen names.
    /// Lifted to ``CmuxWindowing/DisplayInfo``; aliased so existing
    /// `AppDelegate.DisplayInfo` references stay source-identical.
    typealias DisplayInfo = CmuxWindowing.DisplayInfo

    /// All currently-connected displays, in `NSScreen.screens` order.
    func availableDisplays() -> [DisplayInfo] {
        let mainID = NSScreen.main?.cmuxDisplayID
        return NSScreen.screens.enumerated().map { index, screen in
            let displayID = screen.cmuxDisplayID
            return DisplayInfo(
                name: screen.localizedName,
                index: index,
                displayID: displayID,
                isMain: displayID != nil && displayID == mainID,
                frame: screen.frame
            )
        }
    }

    /// Resolve a display from a query: case-insensitive exact name, then
    /// case-insensitive substring, then a zero-based index string. Returns nil
    /// when nothing matches so callers can report the available names.
    func screenMatching(_ query: String) -> NSScreen? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let screens = NSScreen.screens
        if let exact = screens.first(where: {
            $0.localizedName.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return exact
        }
        let lowered = trimmed.lowercased()
        if let partial = screens.first(where: { $0.localizedName.lowercased().contains(lowered) }) {
            return partial
        }
        if let index = Int(trimmed), index >= 0, index < screens.count {
            return screens[index]
        }
        return nil
    }

    /// Move a single main window onto the display matched by `query`, preserving
    /// its size. Returns the resolved display name, or nil when the window or the
    /// display can't be resolved.
    @discardableResult
    func moveMainWindow(windowId: UUID, toDisplayMatching query: String) -> String? {
        guard let window = windowForMainWindowId(windowId),
              let screen = screenMatching(query) else { return nil }
        repositionPreservingSize(window, onto: screen)
        return screen.localizedName
    }

    /// Move every main window onto the display matched by `query`, preserving
    /// sizes. Returns the resolved display name and the moved window ids, or nil
    /// when the display can't be resolved.
    func moveAllMainWindows(toDisplayMatching query: String) -> (display: String, windowIds: [UUID])? {
        guard let screen = screenMatching(query) else { return nil }
        var moved: [UUID] = []
        for summary in listMainWindowSummaries() {
            guard let window = windowForMainWindowId(summary.windowId) else { continue }
            repositionPreservingSize(window, onto: screen)
            moved.append(summary.windowId)
        }
        return (screen.localizedName, moved)
    }

    /// Reposition `window` so it sits fully inside `screen`, keeping its current
    /// size (clamped to the display) and centering it. Deliberately does NOT
    /// raise, key, or activate the window: `window.display` is not a focus-intent
    /// command, so it must never steal macOS focus (see `focusIntentV2Methods`).
    func repositionPreservingSize(_ window: NSWindow, onto screen: NSScreen) {
        let visible = screen.visibleFrame
        let width = min(window.frame.width, visible.width)
        let height = min(window.frame.height, visible.height)
        var origin = NSPoint(x: visible.midX - width / 2, y: visible.midY - height / 2)
        origin.x = max(visible.minX, min(origin.x, visible.maxX - width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - height))
        let frame = NSRect(x: origin.x, y: origin.y, width: width, height: height).integral
        window.setFrame(frame, display: true, animate: false)
    }
}
