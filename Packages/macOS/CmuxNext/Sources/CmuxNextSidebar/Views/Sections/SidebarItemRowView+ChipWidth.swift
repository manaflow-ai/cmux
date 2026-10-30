import AppKit
import CmuxNextDesign

// The inline chip width measure, split from SidebarItemRowView.swift (file size).
extension SidebarItemRowView {
    /// Width of a chip showing `title` (an unread count or the blue unread `dot`, and the status
    /// indicator while `activity` draws): padding, glyph, gap, label, indicator, badge, padding. Cached per title
    /// and font size, because inline sections measure every item on every layout pass.
    static func chipWidth(title: String, font: NSFont, badge: Int? = nil, dot: Bool = false, activity: Bool = false) -> CGFloat {
        let key = ChipKey(title: title, pointSize: font.pointSize, badge: badge.map { min($0, 100) }, dot: dot, activity: activity)
        if let cached = chipWidths[key] { return cached }
        // The label's own width (a text field adds its cell padding), plus
        // one space2 of slack: measured and drawn widths differ by a few
        // points between window contexts (seen in offscreen renders).
        let label = NSTextField(labelWithString: title)
        label.font = font
        var width = Metrics.space2 + SidebarStyle.iconBox + Metrics.space2 + ceil(label.intrinsicContentSize.width) + Metrics.space2 * 2
        if let badge, badge > 0 { width += UnreadBadgeView.width(count: badge) + Metrics.space2 }
        // The dot's cell: a workspace row's lone glyph with its padding (`RowBadgeView`).
        if dot { width += RowBadgeView.glyphSide + 4 + Metrics.space2 }
        if activity { width += SidebarStyle.indicatorSize + Metrics.space2 }
        if chipWidths.count > 512 { chipWidths.removeAll() }
        chipWidths[key] = width
        return width
    }

    fileprivate struct ChipKey: Hashable {
        var title: String
        var pointSize: CGFloat
        var badge: Int?
        var dot: Bool
        var activity: Bool
    }

    fileprivate static var chipWidths: [ChipKey: CGFloat] = [:]
}
