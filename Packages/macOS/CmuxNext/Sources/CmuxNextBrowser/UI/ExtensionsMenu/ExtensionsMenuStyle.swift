import AppKit
import CmuxNextDesign

/// The Extensions bubble's geometry and type: cmux's popover look (``PopupStyle``: the glass
/// card, small radii, rows inset from the card's edge with their own rounded highlight) laid out
/// as Chrome's and Edge's Extensions menus are: a title with a close button, rows grouped by
/// what they can do on the current site, each with its access under its name, and the footer
/// links. Colors are the cmux theme's (``Palette``), read in the bubble's theme scope; a pinned
/// extension's pin takes the theme's accent (``Palette/accentFill``).
struct ExtensionsMenuStyle {
    /// The bubble's width (Edge's menu, a little narrower).
    let width: CGFloat = 340
    var cornerRadius: CGFloat { PopupStyle.standard.cornerRadius }
    /// Space between the card's edge and a row's highlight.
    var padding: CGFloat { PopupStyle.standard.padding }
    /// Space between a row's highlight and its content.
    let rowInset: CGFloat = 8
    /// Where text and icons start: the padding and the row inset.
    var contentInset: CGFloat { padding + rowInset }
    /// The list scrolls above this height.
    let maxListHeight: CGFloat = 400
    /// The title row: the title, the site under it, and the close button.
    let headerHeight: CGFloat = 48
    /// A section title ("Can see and change this site").
    let sectionHeight: CGFloat = 28
    /// An extension row: the name and its access on two lines.
    let rowHeight: CGFloat = 44
    /// A footer row (Manage Extensions, Get extensions).
    var footerRowHeight: CGFloat { PopupStyle.standard.rowHeight + 4 }
    /// The empty state's height (no extensions installed).
    let emptyHeight: CGFloat = 112
    /// The extension's icon, and the box it is centered in.
    let extensionIcon: CGFloat = 20
    let extensionIconBox: CGFloat = 24
    /// A row's trailing button (side panel, pin, more) and its glyph.
    let squareButton: CGFloat = 28
    let buttonIcon: CGFloat = 16
    /// Space between a row's trailing buttons.
    let buttonSpacing: CGFloat = 2
    /// The footer's glyphs, centered in the extension icon's box.
    let footerIcon: CGFloat = 16
    /// Space between an icon's box and its label.
    let imageLabelSpacing: CGFloat = 10
    /// The close button and its glyph.
    let closeButton: CGFloat = 24
    let closeGlyph: CGFloat = 14
    /// A highlight's corner radius (rows and buttons).
    var highlightRadius: CGFloat { PopupStyle.standard.rowCornerRadius }
    /// The pinned pin's fill: the accent, washed (``Palette/menuHighlight`` strength), and a
    /// little stronger under the pointer.
    let pinnedFillOpacity: CGFloat = 0.18
    let pinnedHoverFillOpacity: CGFloat = 0.28

    var titleFont: NSFont { Typography.bodyEmphasized }
    var subtitleFont: NSFont { Typography.caption }
    var sectionFont: NSFont { Typography.header }
    /// Extension names and the footer.
    var labelFont: NSFont { Typography.body }
    /// The line under an extension's name.
    var detailFont: NSFont { Typography.caption }

    /// The style of every Extensions bubble.
    static let standard = ExtensionsMenuStyle()
}
