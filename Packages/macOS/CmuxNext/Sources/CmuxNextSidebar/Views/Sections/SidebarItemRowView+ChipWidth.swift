import AppKit
import CmuxNextDesign

// The inline chip width measure, split from SidebarItemRowView.swift (file size).
extension SidebarItemRowView {
    /// Width of a chip showing `title` (and an unread count): padding,
    /// glyph, gap, label, badge, padding. Cached per title and font size,
    /// because inline sections measure every item on every layout pass.
    static func chipWidth(title: String, font: NSFont, badge: Int? = nil) -> CGFloat {
        let key = ChipKey(title: title, pointSize: font.pointSize, badge: badge.map { min($0, 100) })
        if let cached = chipWidths[key] { return cached }
        // The label's own width (a text field adds its cell padding), plus
        // one space2 of slack: measured and drawn widths differ by a few
        // points between window contexts (seen in offscreen renders).
        let label = NSTextField(labelWithString: title)
        label.font = font
        var width = Metrics.space2 + SidebarStyle.iconBox + Metrics.space2 + ceil(label.intrinsicContentSize.width) + Metrics.space2 * 2
        if let badge, badge > 0 { width += UnreadBadgeView.width(count: badge) + Metrics.space2 }
        if chipWidths.count > 512 { chipWidths.removeAll() }
        chipWidths[key] = width
        return width
    }

    fileprivate struct ChipKey: Hashable {
        var title: String
        var pointSize: CGFloat
        var badge: Int?
    }

    fileprivate static var chipWidths: [ChipKey: CGFloat] = [:]
}
