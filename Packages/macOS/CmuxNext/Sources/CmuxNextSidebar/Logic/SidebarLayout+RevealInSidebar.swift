import CmuxNextDesign
import CoreGraphics

// Reveal Workspace in Sidebar's scroll (Lawrence msg 20167): a row that was on screen moves the least that shows it
// whole (not at all when it shows), and a row that was off screen (out of view, or hidden in a fold) comes to the
// middle of the list, where the eye finds it.
extension SidebarLayout {
    /// Whether row `key` is drawn and at least partly inside a viewport `height` tall at `offset`.
    func isOnScreen(_ key: SidebarRowKey, at offset: CGFloat, height: CGFloat) -> Bool {
        guard let row = row(for: key) else { return false }
        return row.y + row.height > offset && row.y < offset + height
    }

    /// The offset that shows row `key` in a viewport `height` tall now at `offset`: centred (clamped to the list)
    /// when `centre`, else the least scroll that shows it whole. Nil when no row has `key`.
    func revealInSidebarOffset(_ key: SidebarRowKey, from offset: CGFloat, height: CGFloat, centre: Bool) -> CGFloat? {
        guard let row = row(for: key) else { return nil }
        let list = viewportFrame(height: height), item = ListViewport<SidebarRowKey>.Item(id: key, start: row.y, length: row.height)
        guard centre else { return list.reveal(item, from: offset, padding: Self.revealPadding) }
        return list.clamp(item.start + item.length / 2 - height / 2)
    }
}
