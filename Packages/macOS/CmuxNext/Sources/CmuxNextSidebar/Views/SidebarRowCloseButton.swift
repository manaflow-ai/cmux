import AppKit
import CmuxNextDesign

/// The hover close (✕) of a workspace row: one button, at the row controls' one size (`SidebarStyle.rowSymbolSide`), that at the row's end takes the trailing
/// column, where the status mark gives way until the hover ends (`SidebarRowCloseSpot.end`). Its own hover and press
/// highlight cover the ✕ alone (`SidebarIconButton`), never the row.
extension SidebarIconButton {
    static func rowClose(label: String) -> SidebarIconButton {
        // The Debug `sidebar.rowCloseSpot` lighter choices draw it a point under the row's other controls on purpose.
        SidebarIconButton(icon: .actionClose, side: { SidebarStyle.rowSymbolSide - (SidebarTunables.rowCloseSpot.value.smallerGlyph ? 1 : 0) },
                          label: label)
    }
}

extension SidebarStyle {
    /// A hovered row's close at the row's end: the trailing column, a control wide.
    static func rowCloseFrame(rowWidth: CGFloat, centerY: CGFloat) -> NSRect {
        trailingColumnFrame(rowWidth: rowWidth, centerY: centerY, side: controlSize)
    }
}
