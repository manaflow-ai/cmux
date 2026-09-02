import Foundation
import CmuxSurfaceSelection
import WebKit

/// Installs a document-scoped `selectionchange` bridge and forwards only
/// same-origin, non-password selections to its panel-owned publisher.
@MainActor
final class SurfaceSelectionWebBridge: NSObject, WKScriptMessageHandler {
    static let messageName = "cmuxSurfaceSelectionChanged"

    private weak var webView: WKWebView?
    private weak var publisher: SurfaceSelectionChangeEventPublisher?
    private var workspaceIdProvider: @MainActor () -> UUID?
    private var kind: String
    private var filePath: String?
    let surfaceId: UUID

    init(
        webView: WKWebView,
        surfaceId: UUID,
        publisher: SurfaceSelectionChangeEventPublisher,
        workspaceIdProvider: @escaping @MainActor () -> UUID?,
        kind: String,
        filePath: String?
    ) {
        self.webView = webView
        self.surfaceId = surfaceId
        self.publisher = publisher
        self.workspaceIdProvider = workspaceIdProvider
        self.kind = kind
        self.filePath = filePath
    }

    @discardableResult
    func update(
        workspaceIdProvider: @escaping @MainActor () -> UUID?,
        kind: String,
        filePath: String?
    ) -> Bool {
        let metadataChanged = self.kind != kind || self.filePath != filePath
        self.workspaceIdProvider = workspaceIdProvider
        self.kind = kind
        self.filePath = filePath
        return metadataChanged
    }

    func identity() -> SurfaceSelectionEventIdentity? {
        guard let workspaceId = workspaceIdProvider() else { return nil }
        return SurfaceSelectionEventIdentity.live(
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
    }

    func install() {
        guard let webView else { return }
        let controller = webView.configuration.userContentController
        Self.removeBridgeUserScripts(from: controller)
        controller.removeScriptMessageHandler(forName: Self.messageName)
        controller.add(self, name: Self.messageName)
        controller.addUserScript(
            WKUserScript(
                source: Self.bootstrapScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        webView.evaluateJavaScript(Self.bootstrapScript, completionHandler: nil)
    }

    func stop() {
        guard let webView else { return }
        let controller = webView.configuration.userContentController
        webView.evaluateJavaScript(Self.teardownScript, completionHandler: nil)
        controller.removeScriptMessageHandler(forName: Self.messageName)
        Self.removeBridgeUserScripts(from: controller)
        self.webView = nil
    }

    /// Removes only scripts installed by this bridge. Browser and markdown
    /// controllers share a content controller with unrelated app scripts, so
    /// `removeAllUserScripts()` would silently disable those features.
    private static func removeBridgeUserScripts(from controller: WKUserContentController) {
        let remainingScripts = controller.userScripts.filter { $0.source != Self.bootstrapScript }
        controller.removeAllUserScripts()
        for script in remainingScripts {
            controller.addUserScript(script)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName,
              message.webView === webView,
              Self.accepts(frameInfo: message.frameInfo, webView: webView),
              let publisher,
              publisher.hasOptInSubscriber(),
              let body = message.body as? [String: Any] else {
            return
        }

        if body["lifecycle"] as? String == "document" {
            publisher.cancelPending(surfaceId: surfaceId)
            return
        }

        let url = message.frameInfo.request.url?.absoluteString ?? webView?.url?.absoluteString
        guard let snapshot = Self.snapshot(
            from: body,
            kind: kind,
            filePath: filePath,
            url: url
        ) else { return }
        publisher.signal(
            surfaceId: surfaceId,
            snapshot: snapshot
        )
    }

    /// Main-frame messages are owned by the current page. Subframes must have
    /// the same effective origin as that page; a cross-origin frame can still
    /// run the document script, but its message is discarded before capture.
    static func accepts(frameInfo: WKFrameInfo, webView: WKWebView?) -> Bool {
        guard !frameInfo.isMainFrame else { return true }
        return isSameOrigin(frameInfo.securityOrigin, with: webView?.url)
    }

    static func isSameOrigin(_ origin: WKSecurityOrigin, with url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased() else {
            return false
        }
        let host = (url.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let originHost = origin.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard scheme == origin.protocol.lowercased(), host == originHost else {
            return false
        }
        return normalizedPort(scheme: scheme, port: url.port) ==
            normalizedPort(scheme: scheme, port: origin.port > 0 ? origin.port : nil)
    }

    private static func normalizedPort(scheme: String, port: Int?) -> Int {
        if let port, port > 0 { return port }
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return -1
        }
    }

    static func snapshot(
        from body: [String: Any],
        kind: String,
        filePath: String? = nil,
        url: String? = nil
    ) -> SurfaceSelectionEventSnapshot? {
        guard let hasSelection = body["has_selection"] as? Bool else { return nil }
        if body["suppressed"] as? Bool == true || !hasSelection {
            return .none(kind: kind, filePath: filePath, url: url)
        }
        // The bridge never accepts a password-marked payload. This check
        // remains defensive in case a page sends a malformed message.
        guard body["password"] as? Bool != true,
              let text = body["text"] as? String else {
            return .none(kind: kind, filePath: filePath, url: url)
        }
        return .selected(kind: kind, text: text, filePath: filePath, url: url)
    }

    /// Runs in every document so same-origin frames can report selection.
    /// Native origin validation rejects cross-origin frame messages.
    static let bootstrapScript = #"""
    (() => {
      if (window.__cmuxSurfaceSelectionBridgeTeardown) {
        try { window.__cmuxSurfaceSelectionBridgeTeardown(); } catch (_) {}
      }
      if (window.__cmuxSurfaceSelectionBridgeInstalled) return;
      window.__cmuxSurfaceSelectionBridgeInstalled = true;
      const emit = (payload) => {
        try {
          window.webkit?.messageHandlers?.cmuxSurfaceSelectionChanged?.postMessage(payload);
        } catch (_) {}
      };
      const handler = () => {
        const isPasswordNode = (node) => {
          try {
            const element = node && (node.nodeType === 1 ? node : node.parentElement);
            const tag = String(element?.tagName || '').toLowerCase();
            if (tag === 'input' && String(element.type || '').toLowerCase() === 'password') return true;
            return !!element?.closest?.('input[type="password"], textarea[data-cmux-password]');
          } catch (_) {
            return false;
          }
        };
        const active = document.activeElement;
        if (isPasswordNode(active)) {
          emit({
            has_selection: false,
            suppressed: true
          });
          return;
        }
        const activeTag = String(active?.tagName || '').toLowerCase();
        const isTextControl = activeTag === 'input' || activeTag === 'textarea';
        if (isTextControl && typeof active.selectionStart === 'number' &&
            typeof active.selectionEnd === 'number') {
          const start = active.selectionStart;
          const end = active.selectionEnd;
          const hasControlSelection = end > start;
          emit({
            has_selection: hasControlSelection,
            text: hasControlSelection ? String(active.value || '').slice(start, end) : ''
          });
          return;
        }
        const selection = window.getSelection();
        const anchor = selection?.anchorNode;
        const focus = selection?.focusNode;
        if (isPasswordNode(anchor) || isPasswordNode(focus)) {
          emit({
            has_selection: false,
            suppressed: true
          });
          return;
        }
        const hasSelection = !!selection && selection.rangeCount > 0 && !selection.isCollapsed;
        emit({
          has_selection: hasSelection,
          text: hasSelection ? selection.toString() : ''
        });
      };
      const eventNames = ['selectionchange', 'select', 'focusin', 'input'];
      for (const eventName of eventNames) {
        document.addEventListener(eventName, handler, { passive: true, capture: true });
      }
      window.__cmuxSurfaceSelectionBridgeTeardown = () => {
        for (const eventName of eventNames) {
          document.removeEventListener(eventName, handler, true);
        }
        delete window.__cmuxSurfaceSelectionBridgeInstalled;
        delete window.__cmuxSurfaceSelectionBridgeTeardown;
      };
      emit({ lifecycle: 'document' });
    })();
    """#

    /// Tears down listeners in the currently loaded document before a bridge
    /// is detached. Removing the injected script alone cannot remove listeners
    /// that were already registered by that document.
    static let teardownScript = #"""
    (() => {
      try { window.__cmuxSurfaceSelectionBridgeTeardown?.(); } catch (_) {}
    })();
    """#
}

/// Keeps WebKit bridge ownership aligned with the current WKWebView instance.
@MainActor
final class SurfaceSelectionWebBridgeRegistry {
    private let publisher: SurfaceSelectionChangeEventPublisher
    private var bridges: [ObjectIdentifier: SurfaceSelectionWebBridge] = [:]

    init(publisher: SurfaceSelectionChangeEventPublisher) {
        self.publisher = publisher
    }

    func attach(
        webView: WKWebView,
        surfaceId: UUID,
        workspaceIdProvider: @escaping @MainActor () -> UUID?,
        kind: String,
        filePath: String? = nil
    ) {
        let webViewIdentity = ObjectIdentifier(webView)
        if let existing = bridges[webViewIdentity] {
            guard existing.surfaceId == surfaceId else {
                detach(webView: webView)
                attach(
                    webView: webView,
                    surfaceId: surfaceId,
                    workspaceIdProvider: workspaceIdProvider,
                    kind: kind,
                    filePath: filePath
                )
                return
            }
            let metadataChanged = existing.update(
                workspaceIdProvider: workspaceIdProvider,
                kind: kind,
                filePath: filePath
            )
            if metadataChanged {
                publisher.cancelPending(surfaceId: surfaceId)
            }
            if !publisher.hasRegistration(for: surfaceId) {
                publisher.registerSnapshotSource(
                    surfaceId: surfaceId,
                    sourceIdentity: webViewIdentity,
                    owner: existing,
                    identity: { [weak existing] in existing?.identity() }
                )
            }
            return
        }

        detach(surfaceId: surfaceId)
        let bridge = SurfaceSelectionWebBridge(
            webView: webView,
            surfaceId: surfaceId,
            publisher: publisher,
            workspaceIdProvider: workspaceIdProvider,
            kind: kind,
            filePath: filePath
        )
        bridges[webViewIdentity] = bridge
        publisher.registerSnapshotSource(
            surfaceId: surfaceId,
            sourceIdentity: webViewIdentity,
            owner: bridge,
            identity: { [weak bridge] in bridge?.identity() }
        )
        bridge.install()
    }

    func detach(webView: WKWebView) {
        let identity = ObjectIdentifier(webView)
        guard let bridge = bridges.removeValue(forKey: identity) else { return }
        bridge.stop()
        publisher.unregister(surfaceId: bridge.surfaceId, ifSourceIdentity: identity)
    }

    func detach(surfaceId: UUID) {
        let matching = bridges
            .filter { $0.value.surfaceId == surfaceId }
            .map(\.key)
        for identity in matching {
            guard let bridge = bridges.removeValue(forKey: identity) else { continue }
            bridge.stop()
            publisher.unregister(surfaceId: surfaceId, ifSourceIdentity: identity)
        }
    }
}
