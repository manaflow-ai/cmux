internal import Foundation

/// One selectable swatch in the workspace-color submenu of a sidebar row's
/// context menu.
///
/// A `Sendable` value snapshot of an app-side palette entry. The owning row
/// builds these from its color-settings palette and passes them into
/// ``SidebarWorkspaceColorMenuItem``-driven package views, so the views never
/// import the app-target color-settings type. The ``hex`` string is the
/// canonical color identifier applied when the swatch is chosen; ``name`` is
/// the localized display label.
public struct SidebarWorkspaceColorMenuItem: Identifiable, Equatable, Sendable {
    /// Stable identity for `ForEach`; equals the palette entry's identifier.
    public let id: String
    /// Localized display name shown next to the swatch.
    public let name: String
    /// Hex color string (`#RRGGBB`) applied when this swatch is selected.
    public let hex: String

    /// Creates a color menu item.
    /// - Parameters:
    ///   - id: Stable identity for list diffing.
    ///   - name: Localized display name.
    ///   - hex: Hex color string applied on selection.
    public init(id: String, name: String, hex: String) {
        self.id = id
        self.name = name
        self.hex = hex
    }
}
