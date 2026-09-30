import Foundation

extension Strings {
    /// Popup panel title while the page has no title or address yet.
    static var popupUntitled: String {
        String(localized: "popup.untitled", defaultValue: "Popup", table: "Popups", bundle: .module)
    }

    /// Tooltip of a popup panel's close button.
    static var popupCloseHelp: String {
        String(localized: "popup.closeHelp", defaultValue: "Close Popup (Esc)", table: "Popups", bundle: .module)
    }
}
