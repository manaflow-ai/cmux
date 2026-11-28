public import AppKit

// A machine section's header on screen: the icon picker of a machine's icon
// (`machine.setIcon`) opens beside the header the user right-clicked.
extension SidebarView {
    /// Section `id`'s header row on screen, scrolled into view first; nil
    /// when the header is not shown (a lone machine's list shows none).
    public func sectionRowFrameOnScreen(for id: SectionID) -> CGRect? {
        guard let row = list.displayed.row(for: .section(id)), let window = list.window else { return nil }
        list.scrollToVisible(list.frame(for: row))
        return window.convertToScreen(list.convert(list.frame(for: row), to: nil))
    }
}
