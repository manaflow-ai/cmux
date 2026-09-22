import Foundation
import WebKit

/// Adapts noVNC's connection status into native recovery UI. Observing its
/// status elements also catches RFB failures after a successful HTTP page load.
@MainActor
final class CloudDesktopConnectionObserver: NSObject, WKScriptMessageHandler {
    static let name = "cmuxCloudDesktopConnection"
    static let contentWorld = WKContentWorld.world(name: "cmux.cloud.desktop-connection")
    static let userScript = WKUserScript(
        source: """
        (() => {
          if (location.pathname !== '/vnc.html') return;
          const status = document.getElementById('noVNC_status');
          if (!status || !document.getElementById('noVNC_container')) return;
          let last;
          const report = () => {
            const connected = document.documentElement.classList.contains('noVNC_connected');
            const failed = status.classList.contains('noVNC_status_error') &&
                           status.classList.contains('noVNC_open');
            const connecting = document.documentElement.classList.contains('noVNC_connecting') ||
                               document.documentElement.classList.contains('noVNC_reconnecting');
            const value = connected ? 'connected' : connecting ? 'connecting' : failed ? 'failed' : null;
            if (value && value !== last) {
              last = value;
              window.webkit.messageHandlers['\(name)'].postMessage(value);
            }
          };
          const observer = new MutationObserver(report);
          observer.observe(document.documentElement, { attributes: true, attributeFilter: ['class'] });
          observer.observe(status, { attributes: true, attributeFilter: ['class'] });
          report();
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true,
        in: contentWorld
    )

    private weak var webView: WKWebView?
    private let onChange: @MainActor (URL, Bool) -> Void
    private let onConnecting: (@MainActor (URL) -> Void)?

    init(webView: WKWebView, onConnecting: (@MainActor (URL) -> Void)?, onChange: @escaping @MainActor (URL, Bool) -> Void) {
        self.webView = webView
        self.onChange = onChange
        self.onConnecting = onConnecting
    }

    static func install(on webView: WKWebView, onConnecting: (@MainActor (URL) -> Void)? = nil, onChange: @escaping @MainActor (URL, Bool) -> Void) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: name, contentWorld: contentWorld)
        controller.add(CloudDesktopConnectionObserver(webView: webView, onConnecting: onConnecting, onChange: onChange), contentWorld: contentWorld, name: name)
        if !controller.userScripts.contains(where: { $0.source == userScript.source }) {
            controller.addUserScript(userScript)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.name, message.frameInfo.isMainFrame,
              message.webView === webView, let url = message.frameInfo.request.url,
              let value = message.body as? String, ["connected", "connecting", "failed"].contains(value) else { return }
        if value == "connecting" { onConnecting?(url); return }
        onChange(url, value == "connected")
    }
}
