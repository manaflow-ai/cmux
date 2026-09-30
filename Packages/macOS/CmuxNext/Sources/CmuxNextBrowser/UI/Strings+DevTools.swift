import Foundation

extension Strings {
    /// Title of a Chromium tab's DevTools window.
    static func devToolsWindowTitle(_ page: String?) -> String {
        guard let page, !page.isEmpty else {
            return String(localized: "browser.devtools.windowTitle", defaultValue: "DevTools", bundle: .module)
        }
        return String(localized: "browser.devtools.windowTitleForPage", defaultValue: "DevTools - \(page)", bundle: .module)
    }
}
