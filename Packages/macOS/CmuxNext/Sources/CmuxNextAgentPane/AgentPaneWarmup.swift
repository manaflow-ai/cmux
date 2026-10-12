import AppKit
import WebKit

/// Starts WebKit for the agent pages at the top of launch (cx-z9kz0): its
/// first-use setup and the shared pool's first web content process then run
/// while the windows build, so the first agent page loads sooner (live
/// about 65 ms earlier on a cold launch). The empty page goes once an agent
/// page has loaded or the launch settled on its first terminal frame.
public enum AgentPaneWarmup {
    private static var view: WKWebView?

    public static func start() {
        guard view == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.processPool = AgentPaneView.processPool
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
        self.view = view
    }

    public static func finish() {
        view = nil
    }
}
