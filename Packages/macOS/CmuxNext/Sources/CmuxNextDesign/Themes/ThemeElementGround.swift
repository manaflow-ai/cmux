import Foundation

/// What a ``ThemeElement`` is drawn on (``ThemeElementSample/ground``).
public enum ThemeElementGround: String, CaseIterable, Sendable {
    /// The window, sidebar and tab strip background.
    case window
    /// A row or tab under the pointer.
    case hoveredRow
    /// The selected row or tab.
    case selectedRow
    /// A row or button while pressed.
    case pressedRow
    /// Popovers, menus and the command palette: their card glass over the worst desktop for the theme.
    case popover
    /// The palette's or a panel's highlighted row (`Palette.menuHighlight` over the popover).
    case highlightedRow
    /// A button filled with the accent (`Palette.accentFill`).
    case accentButton
    /// The update button (`Palette.highlight`).
    case updateButton

    /// The ground's name in the playground.
    public var title: String {
        switch self {
        case .window: String(localized: "theme.audit.ground.window", defaultValue: "window", bundle: .module)
        case .hoveredRow: String(localized: "theme.audit.ground.hoveredRow", defaultValue: "hovered row", bundle: .module)
        case .selectedRow: String(localized: "theme.audit.ground.selectedRow", defaultValue: "selected row", bundle: .module)
        case .pressedRow: String(localized: "theme.audit.ground.pressedRow", defaultValue: "pressed row", bundle: .module)
        case .popover: String(localized: "theme.audit.ground.popover", defaultValue: "popover", bundle: .module)
        case .highlightedRow: String(localized: "theme.audit.ground.highlightedRow", defaultValue: "highlighted row", bundle: .module)
        case .accentButton: String(localized: "theme.audit.ground.accentButton", defaultValue: "accent button", bundle: .module)
        case .updateButton: String(localized: "theme.audit.ground.updateButton", defaultValue: "update button", bundle: .module)
        }
    }
}
