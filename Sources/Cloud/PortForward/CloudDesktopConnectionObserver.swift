import Foundation
import WebKit

enum CloudDesktopConnectionState: String, Sendable, Equatable, CaseIterable {
    case connected
    case reconnecting
    case disconnected
    case failed

    var isConnected: Bool { self == .connected }
}

/// Bridges noVNC connection state into the native Cloud Desktop recovery path.
@MainActor
final class CloudDesktopConnectionObserver: NSObject, WKScriptMessageHandler {
    static let name = "cmuxCloudDesktopConnection"
    static let contentWorld = WKContentWorld.world(name: "cmux.cloud.desktop-connection")
    private static let scriptMarker = "cmuxCloudDesktopDocumentIdentity"

    static func userScript(documentIdentity: String) -> WKUserScript {
        let escapedIdentity = documentIdentity
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return WKUserScript(
            source: """
            (() => {
              if (location.pathname !== '/vnc.html') return;
              const \(scriptMarker) = '\(escapedIdentity)';
              const status = document.getElementById('noVNC_status');
              if (!status || !document.getElementById('noVNC_container')) return;
              let last;
              let everConnected = false;
              const report = () => {
                const root = document.documentElement.classList;
                const connected = root.contains('noVNC_connected');
                const reconnecting = root.contains('noVNC_reconnecting') ||
                                     root.contains('noVNC_connecting');
                const failed = status.classList.contains('noVNC_status_error') &&
                               status.classList.contains('noVNC_open');
                if (connected) everConnected = true;
                const value = connected ? 'connected'
                  : failed ? 'failed'
                  : !everConnected ? null
                  : reconnecting ? 'reconnecting'
                  : 'disconnected';
                if (value && value !== last) {
                  last = value;
                  window.webkit.messageHandlers['\(name)'].postMessage({
                    state: value,
                    documentIdentity: \(scriptMarker)
                  });
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
    }

    private weak var webView: WKWebView?
    private let onChange: @MainActor (URL, CloudDesktopConnectionState, String) -> Void

    init(webView: WKWebView, onChange: @escaping @MainActor (URL, CloudDesktopConnectionState, String) -> Void) {
        self.webView = webView
        self.onChange = onChange
    }

    static func install(
        on webView: WKWebView,
        documentIdentity: String,
        onConnecting: (@MainActor (URL) -> Void)? = nil,
        onChange: @escaping @MainActor (URL, CloudDesktopConnectionState, String) -> Void
    ) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: name, contentWorld: contentWorld)
        controller.add(CloudDesktopConnectionObserver(webView: webView) { url, state, identity in
            if state == .reconnecting { onConnecting?(url) }
            onChange(url, state, identity)
        }, contentWorld: contentWorld, name: name)
        installDocumentScript(on: webView, documentIdentity: documentIdentity)
    }

    /// Compatibility overload for existing tests and non-recovery callers.
    static func install(
        on webView: WKWebView,
        onConnecting: (@MainActor (URL) -> Void)? = nil,
        onChange: @escaping @MainActor (URL, Bool) -> Void
    ) {
        install(on: webView, documentIdentity: UUID().uuidString, onConnecting: onConnecting) { url, state, _ in
            guard state != .reconnecting else { return }
            onChange(url, state.isConnected)
        }
    }

    static func installDocumentScript(on webView: WKWebView, documentIdentity: String) {
        let controller = webView.configuration.userContentController
        let retained = controller.userScripts.filter { !$0.source.contains(scriptMarker) }
        controller.removeAllUserScripts()
        for script in retained { controller.addUserScript(script) }
        controller.addUserScript(userScript(documentIdentity: documentIdentity))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.name, message.frameInfo.isMainFrame,
              message.webView === webView, let url = message.frameInfo.request.url,
              let payload = message.body as? [String: Any],
              let raw = payload["state"] as? String,
              let documentIdentity = payload["documentIdentity"] as? String,
              let state = CloudDesktopConnectionState(rawValue: raw) else { return }
        onChange(url, state, documentIdentity)
    }
}
