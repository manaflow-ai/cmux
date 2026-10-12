import AppKit
import WebKit

/// Starts WebKit for the agent pages at the top of launch (experiment).
@MainActor
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
        AgentPaneLaunchTimings.shared.mark("diag.warmup_started")
    }
}
