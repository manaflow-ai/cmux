import AppKit
import CmuxNextDesign

/// The hover close (✕) of a sidebar row that closes what it lists: a workspace row and a tab row listed beneath it
/// draw this one button, at one size, and at the row's end take the trailing column, where the status mark gives
/// way until the hover ends (`SidebarRowCloseSpot.end`). Its own hover and press highlight cover the ✕ alone
/// (`SidebarIconButton`), never the row. Leo 2026-10-28, on the tab rows' middle-click: "when you're hovering over
/// that, I think it also wants the close button on there as well."
extension SidebarIconButton {
    static func rowClose(label: String) -> SidebarIconButton {
        SidebarIconButton(icon: .actionClose, pointSize: { Metrics.smallIconSize - Metrics.space2 - (SidebarTunables.rowCloseSpot.value.smallerGlyph ? 1 : 0) },
                          label: label)
    }
}

extension SidebarStyle {
    /// A hovered row's close at the row's end: the trailing column, a control wide.
    static func rowCloseFrame(rowWidth: CGFloat, centerY: CGFloat) -> NSRect {
        trailingColumnFrame(rowWidth: rowWidth, centerY: centerY, side: controlSize)
    }
}
