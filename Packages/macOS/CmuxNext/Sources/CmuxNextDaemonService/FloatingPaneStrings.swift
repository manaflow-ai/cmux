import Foundation

/// The words of floating panes that a person reads (Resources/FloatingPanes.xcstrings): the titles of the
/// actions and the reason a floating pane has no zoom.
enum FloatingPaneStrings {
    static var float: String {
        String(localized: "floatingPanes.float", defaultValue: "Float Pane", table: "FloatingPanes", bundle: .module)
    }

    static var new: String {
        String(localized: "floatingPanes.new", defaultValue: "New Floating Pane", table: "FloatingPanes", bundle: .module)
    }

    /// The debug action's name; the palette shows it as "Debug: Floating Pane Look".
    static var look: String {
        String(localized: "floatingPanes.look", defaultValue: "Floating Pane Look", table: "FloatingPanes", bundle: .module)
    }

    static var noZoom: String {
        String(localized: "floatingPanes.noZoom", defaultValue: "A floating pane has no zoom.", table: "FloatingPanes", bundle: .module)
    }

    /// The notice of New Floating Pane on a screen that has no tiled pane outside a docked column.
    static var noTiledPane: String {
        String(localized: "floatingPanes.noTiledPane", defaultValue: "A floating pane cannot open here: this screen has no tiled pane outside the dock.",
               table: "FloatingPanes", bundle: .module)
    }

    /// The notice of New Floating Pane when the split made a pane that the act could not float.
    static var notFloated: String {
        String(localized: "floatingPanes.notFloated", defaultValue: "The new pane did not float.", table: "FloatingPanes", bundle: .module)
    }
}
