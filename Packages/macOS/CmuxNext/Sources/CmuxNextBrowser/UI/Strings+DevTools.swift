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

extension Strings {
    static var sidePanelPin: String {
        String(localized: "browser.sidePanel.pin", defaultValue: "Pin to Toolbar", bundle: .module)
    }
    static var sidePanelUnpin: String {
        String(localized: "browser.sidePanel.unpin", defaultValue: "Unpin from Toolbar", bundle: .module)
    }
    static var sidePanelOpenInNewTab: String {
        String(localized: "browser.sidePanel.openInNewTab", defaultValue: "Open in New Tab", bundle: .module)
    }
    static var sidePanelMoreInfo: String {
        String(localized: "browser.sidePanel.moreInfo", defaultValue: "More Options", bundle: .module)
    }
    static var sidePanelClose: String {
        String(localized: "browser.sidePanel.close", defaultValue: "Close Side Panel", bundle: .module)
    }
}
