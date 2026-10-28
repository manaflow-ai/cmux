import Foundation

/// Strings of the popup windows (Resources/Popups.xcstrings).
nonisolated enum PopupStrings {
    /// Popup window title while the page has no title and no address yet
    /// (Chrome's `IDS_DEFAULT_TAB_TITLE`).
    static var popupUntitled: String {
        String(localized: "popup.untitledPage", defaultValue: "Untitled", table: "Popups", bundle: .module)
    }
}
