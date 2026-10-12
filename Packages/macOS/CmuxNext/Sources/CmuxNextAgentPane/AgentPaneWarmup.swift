import AppKit
import WebKit

/// Starts WebKit for the agent pages at the top of launch (cx-z9kz0): its
/// first-use setup and the shared pool's first web content process then run
/// while the windows build, so the first agent page loads sooner (live
/// about 65 ms earlier on a cold launch). The empty page goes once an agent
/// page has loaded or the launch settled (`LaunchSettle`).
public enum AgentPaneWarmup {
    private static var view: WKWebView?
    private static let diagDelegate = WarmupDiagDelegate() // diag (to drop)

    public static func start() {
        guard view == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.processPool = AgentPaneView.processPool
        // diag (to drop): load the real page here to see how early it can be live.
        let source = AgentPaneView.bundledPage.map { AgentPaneSource.bundled($0) }
        configuration.userContentController.addUserScript(WKUserScript(source: """
        window.__cmuxT = {docStart: performance.now()};
        document.addEventListener('DOMContentLoaded', () => { window.__cmuxT.dcl = performance.now();
          requestAnimationFrame(() => { window.__cmuxT.raf1 = performance.now(); }); });
        new PerformanceObserver((list) => { for (const e of list.getEntries()) window.__cmuxT[e.name] = e.startTime; }).observe({type: 'paint', buffered: true});
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        view.navigationDelegate = diagDelegate
        AgentPaneLaunchTimings.shared.mark("diag.warm.load")
        // probe1 (to drop): an inline page, no scheme handler: when does the web process run its JS?
        _ = source
        view.loadHTMLString("<!doctype html><title></title><script>window.__cmuxT.script = performance.now()</script>", baseURL: nil)
        self.view = view
    }

    public static func finish() {
        view = nil
    }
}

/// diag (to drop): the warm-up page's navigation and page timings, as `diag.warm.*` marks.
private final class WarmupDiagDelegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        AgentPaneLaunchTimings.shared.mark("diag.warm.nav_start")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        AgentPaneLaunchTimings.shared.mark("diag.warm.nav_commit")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        AgentPaneLaunchTimings.shared.mark("diag.warm.page_loaded")
        webView.callAsyncJavaScript("await new Promise(r => setTimeout(r, 300)); const t = window.__cmuxT || {}; return JSON.stringify(Object.entries(t).map(([k, v]) => [k, performance.timeOrigin + v]));", arguments: [:], in: nil, in: .page) { result in
            guard case .success(let value) = result, let text = value as? String, let data = text.data(using: .utf8),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return }
            for row in rows where row.count == 2 {
                guard let name = row[0] as? String, let at = row[1] as? Double else { continue }
                AgentPaneLaunchTimings.shared.mark("diag.warm.t.\(name)@\(at)")
            }
        }
    }
}
