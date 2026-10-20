import AppKit
import CmuxNextDesign

/// The Extensions bubble's geometry and type, copied from Chrome's legacy Extensions menu
/// (`ExtensionsMenuView`, the menu Chrome shows on desktop while `ExtensionsMenuAccessControl` is
/// off): `chrome/browser/ui/views/extensions/extensions_menu_view.cc` and
/// `extensions_menu_item_view.cc`, with the distances of `chrome_layout_provider.cc`. Colors are
/// the cmux theme's (``Palette``), read in the bubble's theme scope; cmux has no accent color, so
/// a pinned extension's pin draws in the primary text color where Chrome draws its blue.
struct ExtensionsMenuStyle {
    /// `DISTANCE_BUBBLE_PREFERRED_WIDTH`: the legacy menu's fixed width.
    let width: CGFloat = 320
    /// `kDialogRadius` (`kMediumSmall`).
    let cornerRadius: CGFloat = 12
    /// `INSETS_DIALOG`: the bubble's side and title insets.
    let dialogInset: CGFloat = 20
    /// The list scrolls above this height (`kMaxExtensionButtonsHeightDp`).
    let maxListHeight: CGFloat = 448
    /// `DISTANCE_EXTENSIONS_MENU_EXTENSION_ICON_SIZE`: the extension icon's box.
    let extensionIconBox: CGFloat = 28
    /// The extension action icon inside its box (`ExtensionAction::ActionIconSize`).
    let extensionIcon: CGFloat = 16
    /// `DISTANCE_EXTENSIONS_MENU_BUTTON_ICON_SIZE`: the pin, more and settings glyphs.
    let buttonIcon: CGFloat = 20
    /// `DISTANCE_EXTENSIONS_MENU_BUTTON_MARGIN`: the padding around a pin or more glyph.
    let buttonMargin: CGFloat = 12
    /// `DISTANCE_EXTENSIONS_MENU_ICON_SPACING`: (28 − 20) / 2, lines the footer gear up with the
    /// extension icons.
    var iconSpacing: CGFloat { (extensionIconBox - buttonIcon) / 2 }
    /// The primary button's vertical border (12 − 4).
    let primaryVerticalInset: CGFloat = 8
    /// `DISTANCE_RELATED_LABEL_HORIZONTAL`: HoverButton's space between image and label.
    let imageLabelSpacing: CGFloat = 12
    /// `kExtensionsMenuButtonRadius`: the hover highlight's corner radius.
    let highlightRadius: CGFloat = 4
    /// The close button (16 glyph and a 4 inset).
    let closeButton: CGFloat = 24
    let closeGlyph: CGFloat = 16

    /// A row: the icon box between the primary button's borders.
    var rowHeight: CGFloat { extensionIconBox + primaryVerticalInset * 2 }
    /// A pin or more button: the glyph and its margin on each side.
    var squareButton: CGFloat { buttonIcon + buttonMargin * 2 }

    /// Chrome's `STYLE_HEADLINE_4` is 16 pt medium; cmux's type scale has no 16, so the title
    /// takes its nearest step (title, emphasis).
    var titleFont: NSFont { .systemFont(ofSize: TypeScale.title, weight: TypeScale.emphasis) }
    /// Chrome's default label size (`kDefaultSize`, 12 pt): extension names and the footer.
    var labelFont: NSFont { .systemFont(ofSize: TypeScale.detail, weight: TypeScale.regular) }

    /// Chrome's style for every Extensions bubble.
    static let chrome = ExtensionsMenuStyle()
}
