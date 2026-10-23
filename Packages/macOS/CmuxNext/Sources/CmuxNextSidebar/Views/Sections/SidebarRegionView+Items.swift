import AppKit
import CmuxNextDesign

extension SidebarRegionView {
    /// Icon + label width of every item of an inline section. The profile
    /// control is the avatar alone, never a labeled chip (Leo and Lawrence 2026-10-20).
    static func labelWidths(_ content: Content, width: CGFloat) -> [LayoutItemID: CGFloat] {
        var widths: [LayoutItemID: CGFloat] = [:]
        let font = SidebarStyle.titleFont
        // Inline lines and span grids (R53) draw labeled items with icon and label.
        for section in content.sections where section.arrangement.layout == .inline
            || (section.arrangement.layout == .grid && section.items.contains { $0.span != nil }) {
            for item in section.items {
                let info = content.infos[item.id] ?? .fallback(for: item)
                if info.avatar == nil, item.showsLabel {
                    widths[item.id] = SidebarItemRowView.chipWidth(title: info.title, font: font, badge: info.badge, dot: info.unreadDot, activity: info.activity != .idle)
                }
            }
        }
        return widths
    }

    /// Edit mode on an item: never on a client-only item (What's New) or a drag's gap.
    func edit(_ view: SidebarItemRowView, _ id: LayoutItemID) {
        view.isEditing = isEditing && !id.isTransient && id != SidebarListBlocks.gapID
    }
}
