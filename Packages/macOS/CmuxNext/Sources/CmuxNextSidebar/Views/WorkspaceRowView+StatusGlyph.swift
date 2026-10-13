import AppKit
import CmuxNextDesign

extension WorkspaceRowView {
    /// The status mark's frame (the shared indicator, or the agent mark standing in for it) ending
    /// at `trailing`: as tall as the unread badge, centered on the middle of the title's capitals,
    /// on the pixel grid. The title is top-aligned at `titleTop`, its baseline the font's ascender
    /// below (MarqueeLabel). Leo 2026-10-13: a 10 pt mark on the row's box center read small and
    /// low beside the badge.
    func statusGlyphFrame(trailing: CGFloat, titleTop: CGFloat) -> NSRect {
        let side = SidebarStyle.statusGlyphSize
        let font = title.font
        let center = titleTop + font.ascender - font.capHeight / 2
        let scale = window?.backingScaleFactor ?? 2
        func snapped(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        return NSRect(x: snapped(trailing - side), y: snapped(center - side / 2), width: side, height: side)
    }

    /// The agent mark's image size: the status mark's when it stands in for the status, the
    /// indicator size when it sits beside the title, so its brand variant matches the box it fills.
    var agentMarkSize: CGFloat {
        agentMarkVariant == .replacesStatus ? SidebarStyle.statusGlyphSize : SidebarStyle.indicatorSize
    }
}
