import AppKit

/// Chromium's views drag threshold on macOS, in points.
let omnibarDragThreshold: CGFloat = 5

extension NSEvent {
    /// Whether this press in the omnibar was a drag: `release` (the event
    /// AppKit's text tracking ended on, normally the mouse-up) landed past
    /// the drag threshold from the press, in window points. The field moves
    /// under a still pointer when it takes focus, so the selection AppKit
    /// tracked cannot say it (macOS 15). A nil or non-mouse `release`, or one
    /// in another window, counts as no drag.
    func omnibarDragged(to release: NSEvent?) -> Bool {
        guard let release, release.type == .leftMouseUp || release.type == .leftMouseDragged,
              release.windowNumber == windowNumber else { return false }
        let dx = release.locationInWindow.x - locationInWindow.x
        let dy = release.locationInWindow.y - locationInWindow.y
        return dx * dx + dy * dy > omnibarDragThreshold * omnibarDragThreshold
    }
}
