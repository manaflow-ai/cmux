import CmuxChromium
import Foundation

/// Live Chromium engine state for one browser surface.
@MainActor
final class BrowserPanelChromiumState {
    let session: ChromiumSession
    let model: ChromiumBrowserModel
    let webView: ChromiumWebView
    var pollTask: Task<Void, Never>?
    var nativeSurfaceCoordinator: BrowserChromiumNativeSurfaceCoordinator?

    init(session: ChromiumSession, model: ChromiumBrowserModel, webView: ChromiumWebView) {
        self.session = session
        self.model = model
        self.webView = webView
    }

    func teardown() {
        pollTask?.cancel()
        pollTask = nil
        webView.onSurfaceTree = nil
        webView.onPointerClick = nil
        webView.onDidBecomeFirstResponder = nil
        webView.acceptsFirstMouseProvider = nil
        nativeSurfaceCoordinator = nil
        session.close()
    }
}
