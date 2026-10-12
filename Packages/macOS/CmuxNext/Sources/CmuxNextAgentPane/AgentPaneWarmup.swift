import AppKit
import WebKit

/// Starts WebKit for the agent pages at the top of launch (cx-z9kz0): its
/// first-use setup and the shared pool's first web content process then run
/// while the windows build, so the first agent page loads sooner (live
/// about 65 ms earlier on a cold launch). The empty page goes once an agent
/// page has loaded or the launch settled (`LaunchSettle`).
///
/// It also has the pool start one more web content process with no page,
/// set up while the windows build, which the first agent page takes: a
/// page in a new process waited for that process's setup, which needs main
/// thread turns the launch does not give it until about 450 ms (bd cx-z9kz0).
public enum AgentPaneWarmup {
    private static var view: WKWebView?
    /// The in-memory data store every agent page shares. WebKit gives each store its own web
    /// processes, so a fresh store per page could not use the one started here. Storage the
    /// page keys per chat (drafts) stays per chat; the rest is app-wide choices.
    static let dataStore = WKWebsiteDataStore.nonPersistent()

    public static func start() {
        guard view == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.processPool = AgentPaneView.processPool
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
        self.view = view
        // WebKit's prewarmed process (`-[WKProcessPool _warmInitialProcess]`), checked first: macOS
        // has no public call for it; without it the first page starts its own process.
        let prewarm = NSSelectorFromString("_warmInitialProcess") // crash-allow: performed only when the pool responds to it
        if AgentPaneView.processPool.responds(to: prewarm) { _ = AgentPaneView.processPool.perform(prewarm) }
    }

    public static func finish() {
        view = nil
    }
}
