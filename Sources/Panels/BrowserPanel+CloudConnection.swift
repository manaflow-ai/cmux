import Foundation
import WebKit

extension BrowserPanel {
    func installCloudDesktopConnectionObserver(on webView: WKWebView) {
        let isCurrent = webViewObservationValidator(for: webView)
        CloudDesktopConnectionObserver.install(on: webView) { [weak self] url, isConnected in
            guard let self, isCurrent() else { return }
            self.cloudAccess.desktopConnectionDidChange(url: url, isConnected: isConnected)
        }
    }

    func preferredURLStringForSessionSnapshot() -> String? {
        if let serviceURL = cloudAccess.sessionURL(currentURL: currentURL) { return serviceURL.absoluteString }
        if let displayURL = restorableDisplayURLForCurrentErrorPage(liveURL: webView.url),
           let value = Self.serializableSessionHistoryURLString(displayURL) {
            return value
        }
        if let currentURL,
           let value = Self.serializableSessionHistoryURLString(currentURL) {
            return value
        }
        return nil
    }
}
