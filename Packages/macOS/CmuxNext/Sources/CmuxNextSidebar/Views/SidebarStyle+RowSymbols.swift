import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The one size of every symbol on a sidebar row: a pinned row's leading pin and a hovered row's trailing controls
/// (Pin or Unpin, the menu ⋮, the close ✕, the tree's chevron, the speaker), on workspace rows, pinned rows and group
/// headers alike. https://github.com/manaflow-ai/cmux/issues/49583: "are all of these the same size icons wise… look at
/// the top left one". The leading pin drew at the rows' optical size while the hover pin and ✕ drew at
/// `smallIconSize - space2` and the ⋮ at `smallIconSize - space1`, three sizes and so three stroke weights in one row.
extension SidebarStyle {
    /// The side every row symbol's image draws at: the side the leading pin takes once its ink fills the rows' one
    /// optical square (`rowGlyphOptics`), so the hover pin is the leading pin's size and the ⋮ and ✕ beside it share
    /// that scale and that stroke (the pack draws every glyph on one 24 pt grid with one stroke width). Never past a
    /// control's square, the hit box every trailing control takes (`controlSize`), on half points so it draws crisp, and
    /// never under the pack's smallest icon (`iconFloor`), which every glyph clamps to: below it the hover controls would
    /// draw at the floor while the side said less (Ultra-compact's 11.5 pt).
    @MainActor static var rowSymbolSide: CGFloat {
        let base = pinGlyphSide
        let image = NSImage.icon(.statePinned, size: base, style: .solid)
        let fitted = SidebarGlyphInk.shared.box(of: image, glyph: SidebarItemRowView.pinGlyph)
            .map { SidebarOpticalGlyph.fittedExtent($0.size) } ?? 0
        let side = fitted > 0 ? base * rowGlyphOpticalSide / fitted : base
        return min(controlSize, max(.iconFloor, (side * 2).rounded() / 2))
    }
}

extension SidebarIconButton {
    /// A row's trailing control (Pin, Unpin, ✕, the tree's chevron, the speaker): its glyph at `rowSymbolSide`, in a
    /// `controlSize` square the row frames on its center line.
    static func rowControl(icon: IconName, label: String) -> SidebarIconButton {
        SidebarIconButton(icon: icon, side: { SidebarStyle.rowSymbolSide }, label: label)
    }
}

extension OverflowButton {
    /// A row's menu ⋮ at `rowSymbolSide`, the size of the controls beside it.
    static func rowControl(label: String) -> OverflowButton {
        let button = OverflowButton(label: label)
        button.glyphSide = { SidebarStyle.rowSymbolSide }
        return button
    }
}
