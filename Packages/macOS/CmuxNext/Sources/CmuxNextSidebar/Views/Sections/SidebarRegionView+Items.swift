import AppKit
import CmuxNextDesign

extension SidebarRegionView {
    /// Icon + label width of every item of an inline section; the profile
    /// control's avatar + name width where the line has room for it.
    static func labelWidths(_ content: Content, width: CGFloat) -> [LayoutItemID: CGFloat] {
        var widths: [LayoutItemID: CGFloat] = [:]
        let font = SidebarStyle.titleFont
        let line = width - content.metrics.inset * 2
        // Inline lines and span grids (R53) draw labeled items with icon and label.
        for section in content.sections where section.arrangement.layout == .inline
            || (section.arrangement.layout == .grid && section.items.contains { $0.span != nil }) {
            for item in section.items {
                let info = content.infos[item.id] ?? .fallback(for: item)
                // The profile control alone on an inline line (the default footer) is one chip,
                // avatar, name and chevron, whether or not the item asks for a label (Leo
                // 2026-10-20, #14893); without room, or beside other items, it keeps its look.
                if info.avatar != nil, section.arrangement.layout == .inline, section.items.count == 1 {
                    widths[item.id] = SidebarItemRowView.profileChipWidth(rowHeight: content.metrics.rowHeight, available: line)
                } else if item.showsLabel {
                    widths[item.id] = SidebarItemRowView.chipWidth(title: info.title, font: font, badge: info.badge, activity: info.activity != .idle)
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
