import WebKit

struct BrowserWebExtensionNavigationConfiguration {
    let contextIdentifier: ObjectIdentifier
    let webViewConfiguration: WKWebViewConfiguration
}

extension BrowserPanel {
    func shouldBlockWebExtensionNavigation(to url: URL, allowWebExtensionContext: Bool) -> Bool {
        guard !allowWebExtensionContext else { return false }
        if browserWebExtensionHost?.webViewConfiguration(forNavigatingTo: url) != nil {
            return true
        }
        return url.scheme?.lowercased() == "webkit-extension"
    }

    func shouldBlockPageInitiatedWebExtensionNavigation(to url: URL) -> Bool {
        let targetContextIdentifier = browserWebExtensionHost?
            .webViewConfiguration(forNavigatingTo: url)?
            .contextIdentifier
        if let targetContextIdentifier,
           targetContextIdentifier == webExtensionPageContextIdentifier {
            return false
        }
        if webExtensionPageContextIdentifier != nil,
           !canOpenPageInitiatedWebExtensionExitURL(url) {
            return true
        }
        return targetContextIdentifier != nil || url.scheme?.lowercased() == "webkit-extension"
    }

    func shouldRoutePageInitiatedWebExtensionNavigationInCurrentTab(to url: URL) -> Bool {
        guard webExtensionPageContextIdentifier != nil,
              canOpenPageInitiatedWebExtensionExitURL(url) else { return false }
        let targetContextIdentifier = browserWebExtensionHost?
            .webViewConfiguration(forNavigatingTo: url)?
            .contextIdentifier
        return targetContextIdentifier != webExtensionPageContextIdentifier
    }

    func canOpenPageInitiatedWebExtensionExitURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return true }
        return scheme == "http" || scheme == "https" || scheme == "about"
    }
}
