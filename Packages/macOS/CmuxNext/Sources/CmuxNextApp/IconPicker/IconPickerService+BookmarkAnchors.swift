import AppKit
import CmuxNextBookmarks

// Anchors at a bookmark folder: its icon picker opens beside the folder's item
// on a bookmarks bar, like the bar's folder menus.
extension IconPickerService {
    /// An anchor at bookmark `id`'s item on a bookmarks bar in the active
    /// window; else, when a click chose the action (a manager page row's or a
    /// folder menu's right-click menu), at the pointer, beside the row it was
    /// chosen for; else the top middle of the active window.
    func anchor(bookmark id: String) -> Anchor? {
        guard let window = services?.windows.active?.window, let content = window.contentView else { return activeWindowAnchor() }
        let bars = services?.bookmarks.chromes.values.map(\.bar).filter { $0.window === window } ?? []
        if let item = bars.lazy.compactMap({ $0.itemFrameOnScreen(id) }).first {
            return Anchor(view: content, rect: content.convert(window.convertFromScreen(item), from: nil))
        }
        // A menu item chosen by mouse: the pointer is on the menu, beside the row it opened on.
        let clicks: [NSEvent.EventType] = [.leftMouseUp, .rightMouseUp, .otherMouseUp, .leftMouseDown, .rightMouseDown]
        if let event = services?.inputTap.actionEvent, clicks.contains(event.type) {
            let pointer = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if content.bounds.contains(pointer) {
                return Anchor(view: content, rect: NSRect(x: pointer.x - 1, y: pointer.y - 1, width: 2, height: 2))
            }
        }
        return activeWindowAnchor()
    }
}
