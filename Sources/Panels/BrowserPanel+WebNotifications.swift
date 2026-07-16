import CmuxSettings
import Foundation
import WebKit

extension BrowserPanel {
    /// Builds the page-world wrapper installed at document start for one webview generation.
    static func webNotificationBridgeScriptSource(token: String) -> String {
        guard let tokenData = try? JSONEncoder().encode(token),
              let tokenLiteral = String(data: tokenData, encoding: .utf8) else {
            return ""
        }

        return """
        (() => {
          const NativeNotification = window.Notification;
          if (typeof NativeNotification !== "function") return false;

          const globalDescriptor = Object.getOwnPropertyDescriptor(window, "Notification");
          if (!globalDescriptor || !globalDescriptor.configurable) return false;

          function ForwardingNotification() {
            const capturedPermission = NativeNotification.permission;
            const notification = new.target
              ? Reflect.construct(
                  NativeNotification,
                  arguments,
                  new.target === ForwardingNotification ? NativeNotification : new.target
                )
              : Reflect.apply(NativeNotification, this, arguments);

            if (capturedPermission === "granted") {
              try {
                window.webkit.messageHandlers["\(BrowserWebNotificationMessageHandler.name)"].postMessage({
                  token: \(tokenLiteral),
                  title: typeof notification.title === "string" ? notification.title : "",
                  body: typeof notification.body === "string" ? notification.body : ""
                });
              } catch (_) {}
            }
            return notification;
          }

          try { Object.setPrototypeOf(ForwardingNotification, NativeNotification); } catch (_) {}
          ForwardingNotification.prototype = NativeNotification.prototype;
          for (const key of Reflect.ownKeys(NativeNotification)) {
            if (key === "length" || key === "name" || key === "prototype") continue;
            try {
              Object.defineProperty(
                ForwardingNotification,
                key,
                Object.getOwnPropertyDescriptor(NativeNotification, key)
              );
            } catch (_) {}
          }

          Object.defineProperty(window, "Notification", {
            ...globalDescriptor,
            value: ForwardingNotification
          });
          return true;
        })();
        """
    }

    /// Installs a token-bound bridge for the currently bound browser webview.
    func setupWebNotificationBridge(for webView: WKWebView) {
        let token = UUID().uuidString
        let boundWebViewInstanceID = webViewInstanceID
        let handler = BrowserWebNotificationMessageHandler(
            webView: webView,
            token: token,
            webViewInstanceID: boundWebViewInstanceID,
            isCurrentGeneration: { [weak self] candidate, instanceID in
                self?.isCurrentWebView(candidate, instanceID: instanceID) == true
            },
            onPayload: { [weak self] payload, instanceID in
                self?.handleWebNotificationPayload(payload, fromWebViewInstanceID: instanceID)
            }
        )

        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(
            forName: BrowserWebNotificationMessageHandler.name,
            contentWorld: .page
        )
        controller.add(
            handler,
            contentWorld: .page,
            name: BrowserWebNotificationMessageHandler.name
        )
        controller.addUserScript(
            WKUserScript(
                source: Self.webNotificationBridgeScriptSource(token: token),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            )
        )

        webNotificationMessageHandler = handler
        webNotificationBridgeToken = token
    }

    /// Removes the native endpoint before a browser webview is released or superseded.
    func tearDownWebNotificationBridge(from webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: BrowserWebNotificationMessageHandler.name,
            contentWorld: .page
        )
        webNotificationMessageHandler = nil
        webNotificationBridgeToken = nil
    }

    /// Routes a validated website notification through cmux's existing notification policy.
    func handleWebNotificationPayload(
        _ payload: BrowserWebNotificationPayload,
        fromWebViewInstanceID instanceID: UUID
    ) {
        guard instanceID == webViewInstanceID else { return }
        let setting = SettingCatalog().browser.forwardWebNotifications
        guard setting.value(in: .standard) else { return }

        deliverWebNotification(
            workspaceId,
            id,
            payload.title,
            payload.hostname,
            payload.body
        )
    }
}
