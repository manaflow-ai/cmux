import Foundation

extension Strings {
    /// Title of a Chromium tab's DevTools window.
    static func devToolsWindowTitle(_ page: String?) -> String {
        guard let page, !page.isEmpty else {
            return String(localized: "browser.devtools.windowTitle", defaultValue: "DevTools", bundle: .localizedModule)
        }
        return String(localized: "browser.devtools.windowTitleForPage", defaultValue: "DevTools - \(page)", bundle: .localizedModule)
    }
}

extension Strings {
    static var sidePanelPin: String {
        String(localized: "browser.sidePanel.pin", defaultValue: "Pin to Toolbar", bundle: .localizedModule)
    }
    static var sidePanelUnpin: String {
        String(localized: "browser.sidePanel.unpin", defaultValue: "Unpin from Toolbar", bundle: .localizedModule)
    }
    static var sidePanelOpenInNewTab: String {
        String(localized: "browser.sidePanel.openInNewTab", defaultValue: "Open in New Tab", bundle: .localizedModule)
    }
    static var sidePanelMoreInfo: String {
        String(localized: "browser.sidePanel.moreInfo", defaultValue: "More Options", bundle: .localizedModule)
    }
    static var sidePanelClose: String {
        String(localized: "browser.sidePanel.close", defaultValue: "Close Side Panel", bundle: .localizedModule)
    }
}
