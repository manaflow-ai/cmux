public import Foundation

/// Which URLs a Chrome extension may put in a browser tab through
/// `tabs.create`, `tabs.update`, `windows.create`, or its options page.
///
/// Extension navigation never takes cmux's trusted internal-load path, and
/// schemes that execute script or read local state (`javascript:`, `file:`,
/// `data:`, `blob:`, `cmux:`) are refused outright, as Chrome refuses them.
public enum ChromeExtensionNavigationPolicy {
    public static let extensionScheme = "chrome-extension"

    /// Whether `extensionID` may navigate a tab to `url`.
    public static func allows(_ url: URL, fromExtensionID extensionID: String) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return url.host?.isEmpty == false
        case "about":
            return url.absoluteString.lowercased() == "about:blank"
        case extensionScheme:
            // Only the extension's own pages; another extension's pages are
            // not an extension's to open.
            return url.host?.lowercased() == extensionID.lowercased()
        default:
            return false
        }
    }
}
