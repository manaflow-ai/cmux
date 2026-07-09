import CmuxChromium
import Foundation

/// Live Chromium engine state for one browser surface.
@MainActor
final class BrowserPanelChromiumState {
    let session: ChromiumSession
    let model: ChromiumBrowserModel
    let webView: ChromiumWebView
    var eventTask: Task<Void, Never>?
    var pollTask: Task<Void, Never>?

    init(session: ChromiumSession, model: ChromiumBrowserModel, webView: ChromiumWebView) {
        self.session = session
        self.model = model
        self.webView = webView
    }

    func teardown() {
        eventTask?.cancel()
        eventTask = nil
        pollTask?.cancel()
        pollTask = nil
        session.close()
    }
}
