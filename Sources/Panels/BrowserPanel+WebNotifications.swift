import AppKit
import CmuxBrowser
import CmuxFoundation
import CmuxSettings
import Foundation
import ObjectiveC
import WebKit

private final class BrowserWebNotificationBridgeConfiguration: NSObject {
    let token: String
    let profileID: UUID

    init(token: String, profileID: UUID) {
        self.token = token
        self.profileID = profileID
    }
}

extension BrowserPanel {
    private static var webNotificationBridgeConfigurationKey: UInt8 = 0

    /// Builds the page-world compatibility wrapper used when native WebKit
    /// notification delivery is unavailable at runtime.
    static func webNotificationBridgeScriptSource(
        token: String,
        allowedOrigins: Set<String> = [],
        deniedOrigins: Set<String> = []
    ) -> String {
        guard let tokenLiteral = token.javaScriptStringLiteral,
              let allowedData = try? JSONEncoder().encode(allowedOrigins.sorted()),
              let allowedLiteral = String(data: allowedData, encoding: .utf8),
              let deniedData = try? JSONEncoder().encode(deniedOrigins.sorted()),
              let deniedLiteral = String(data: deniedData, encoding: .utf8) else {
            return ""
        }

        return """
        (() => {
          const NativeNotification = window.Notification;
          if (typeof NativeNotification !== "function") return false;

          const globalDescriptor = Object.getOwnPropertyDescriptor(window, "Notification");
          if (!globalDescriptor || !globalDescriptor.configurable) return false;

          const allowedOrigins = new Set(\(allowedLiteral));
          const deniedOrigins = new Set(\(deniedLiteral));
          let managedPermission = allowedOrigins.has(location.origin)
            ? "granted"
            : (deniedOrigins.has(location.origin) ? "denied" : "default");

          function ForwardingNotification(title, options) {
            const notification = Reflect.construct(
              NativeNotification,
              arguments,
              new.target === ForwardingNotification ? NativeNotification : new.target
            );

            if (managedPermission === "granted") {
              try {
                window.webkit.messageHandlers["\(BrowserWebNotificationMessageHandler.name)"].postMessage({
                  type: "notification",
                  token: \(tokenLiteral),
                  title: typeof notification.title === "string" ? notification.title : String(title ?? ""),
                  body: typeof notification.body === "string" ? notification.body : String(options?.body ?? "")
                });
              } catch (_) {}
            }
            return notification;
          }

          try { Object.setPrototypeOf(ForwardingNotification, NativeNotification); } catch (_) {}
          ForwardingNotification.prototype = NativeNotification.prototype;
          try {
            Object.defineProperty(ForwardingNotification.prototype, "constructor", {
              value: ForwardingNotification,
              configurable: true,
              writable: true
            });
          } catch (_) {}

          for (const key of Reflect.ownKeys(NativeNotification)) {
            if (key === "prototype" || key === "permission" || key === "requestPermission") continue;
            try {
              Object.defineProperty(
                ForwardingNotification,
                key,
                Object.getOwnPropertyDescriptor(NativeNotification, key)
              );
            } catch (_) {}
          }
          try {
            Object.defineProperty(ForwardingNotification, "name", {
              value: NativeNotification.name,
              configurable: true
            });
            Object.defineProperty(ForwardingNotification, "length", {
              value: NativeNotification.length,
              configurable: true
            });
          } catch (_) {}
          Object.defineProperty(ForwardingNotification, "permission", {
            configurable: true,
            enumerable: true,
            get: () => managedPermission
          });
          Object.defineProperty(ForwardingNotification, "requestPermission", {
            configurable: true,
            writable: true,
            value: function requestPermission(callback) {
              const promise = Promise.resolve(
                window.webkit.messageHandlers["\(BrowserWebNotificationMessageHandler.name)"].postMessage({
                  type: "permission",
                  token: \(tokenLiteral)
                })
              ).then(value => {
                managedPermission = value === "granted" ? "granted" : "denied";
                if (typeof callback === "function") callback(managedPermission);
                return managedPermission;
              }, () => {
                managedPermission = "denied";
                if (typeof callback === "function") callback(managedPermission);
                return managedPermission;
              });
              return promise;
            }
          });

          const permissionReady = Promise.resolve(
            window.webkit.messageHandlers["\(BrowserWebNotificationMessageHandler.name)"].postMessage({
              type: "status",
              token: \(tokenLiteral)
            })
          ).then(value => {
            if (value === "granted" || value === "denied" || value === "default") {
              managedPermission = value;
            }
            return managedPermission;
          }, () => managedPermission);
          try {
            Object.defineProperty(window, "__cmuxWebNotificationPermissionReady", {
              value: permissionReady,
              configurable: true
            });
          } catch (_) {}

          const nativePermissions = navigator.permissions;
          if (nativePermissions && typeof nativePermissions.query === "function") {
            const nativeQuery = nativePermissions.query.bind(nativePermissions);
            try {
              nativePermissions.query = descriptor => {
                if (descriptor?.name !== "notifications") return nativeQuery(descriptor);
                return Promise.resolve({
                  get state() { return managedPermission === "default" ? "prompt" : managedPermission; },
                  onchange: null,
                  addEventListener() {},
                  removeEventListener() {},
                  dispatchEvent() { return false; }
                });
              };
            } catch (_) {}
          }

          try {
            const replacement = { configurable: globalDescriptor.configurable };
            if ("enumerable" in globalDescriptor) replacement.enumerable = globalDescriptor.enumerable;
            if ("writable" in globalDescriptor) replacement.writable = globalDescriptor.writable;
            replacement.value = ForwardingNotification;
            Object.defineProperty(window, "Notification", replacement);
          } catch (_) {
            return false;
          }
          return true;
        })();
        """
    }

    /// Adds the fallback script before the web view can begin loading, including
    /// views created by the prewarm pool. Opted-out configurations stay pristine.
    static func configureWebNotificationFallback(
        on configuration: WKWebViewConfiguration,
        profileID: UUID
    ) {
        let setting = SettingCatalog().browser.forwardWebNotifications
        guard setting.value(in: .standard),
              BrowserWebNotificationNativeAdapter.shared.shouldInstallForegroundFallback else {
            return
        }
        let permissionRepository = BrowserProfileStore.shared.notificationPermissions
        let bridge = BrowserWebNotificationBridgeConfiguration(token: UUID().uuidString, profileID: profileID)
        objc_setAssociatedObject(
            configuration.userContentController,
            &webNotificationBridgeConfigurationKey,
            bridge,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: webNotificationBridgeScriptSource(
                    token: bridge.token,
                    allowedOrigins: permissionRepository.allowedOrigins(for: profileID),
                    deniedOrigins: permissionRepository.deniedOrigins(for: profileID)
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            )
        )
    }

    /// Binds the native endpoint for a preconfigured compatibility script.
    func setupWebNotificationBridge(for webView: WKWebView) {
        let boundWebViewInstanceID = webViewInstanceID
        let handler = makeWebNotificationMessageHandler(
            for: webView,
            webViewInstanceID: boundWebViewInstanceID,
            isCurrentGeneration: { [weak self] candidate, instanceID in
                self?.isCurrentWebView(candidate, instanceID: instanceID) == true
            }
        )
        webNotificationMessageHandler = handler
        webNotificationBridgeToken = handler?.token
    }

    /// Binds an independently configured popup to the opener's notification
    /// destination without sharing the opener web view's bridge generation.
    func setupPopupWebNotificationBridge(for webView: WKWebView) -> BrowserWebNotificationMessageHandler? {
        let instanceID = UUID()
        return makeWebNotificationMessageHandler(
            for: webView,
            webViewInstanceID: instanceID,
            isCurrentGeneration: { [weak webView] candidate, candidateInstanceID in
                candidate === webView && candidateInstanceID == instanceID
            }
        )
    }

    private func makeWebNotificationMessageHandler(
        for webView: WKWebView,
        webViewInstanceID boundWebViewInstanceID: UUID,
        isCurrentGeneration: @escaping @MainActor (WKWebView, UUID) -> Bool
    ) -> BrowserWebNotificationMessageHandler? {
        BrowserWebNotificationNativeAdapter.shared.register(
            webView: webView,
            profileID: profileID,
            panel: self
        )
        guard let bridge = objc_getAssociatedObject(
            webView.configuration.userContentController,
            &Self.webNotificationBridgeConfigurationKey
        ) as? BrowserWebNotificationBridgeConfiguration else {
            return nil
        }

        let handler = BrowserWebNotificationMessageHandler(
            webView: webView,
            token: bridge.token,
            webViewInstanceID: boundWebViewInstanceID,
            isCurrentGeneration: isCurrentGeneration,
            permissionDecision: { [weak self] origin in
                self?.webNotificationPermissionDecision(for: origin) ?? .denied
            },
            onPayload: { [weak self] payload, _ in
                guard let self else { return }
                self.handleWebNotificationPayload(payload, fromWebViewInstanceID: self.webViewInstanceID)
            },
            onPermissionRequest: { [weak self, weak webView] origin, reply in
                guard let self, let webView else {
                    reply(false)
                    return
                }
                self.resolveWebNotificationPermission(for: origin, in: webView, reply: reply)
            }
        )

        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: BrowserWebNotificationMessageHandler.name, contentWorld: .page)
        controller.addScriptMessageHandler(handler, contentWorld: .page, name: BrowserWebNotificationMessageHandler.name)
        return handler
    }

    /// Removes the endpoint before a browser webview is released or superseded.
    func tearDownWebNotificationBridge(from webView: WKWebView) {
        BrowserWebNotificationNativeAdapter.shared.unregister(webView: webView)
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: BrowserWebNotificationMessageHandler.name,
            contentWorld: .page
        )
        webNotificationMessageHandler = nil
        webNotificationBridgeToken = nil
    }

    /// Resolves an existing site decision or presents a one-time per-origin prompt.
    func resolveWebNotificationPermission(
        for rawOrigin: URL,
        in webView: WKWebView,
        reply: @escaping (Bool) -> Void
    ) {
        guard SettingCatalog().browser.forwardWebNotifications.value(in: .standard) else {
            reply(false)
            return
        }
        let origin = rawOrigin
        let displayOriginURL = Self.remoteProxyDisplayURL(for: origin) ?? origin
        let repository = BrowserProfileStore.shared.notificationPermissions
        switch storedWebNotificationPermissionDecision(for: origin, repository: repository) {
        case .allowed:
            reply(true)
        case .denied:
            reply(false)
        case .prompt:
            let originKey = BrowserNotificationPermissionRepository.canonicalOrigin(origin) ?? origin.absoluteString
            let displayOrigin = BrowserNotificationPermissionRepository.canonicalOrigin(displayOriginURL)
                ?? displayOriginURL.absoluteString
            if pendingWebNotificationPermissionReplies[originKey] != nil {
                pendingWebNotificationPermissionReplies[originKey]?.append(reply)
                return
            }
            pendingWebNotificationPermissionReplies[originKey] = [reply]
            let alert = NSAlert()
            alert.messageText = String(
                localized: "browser.notifications.permission.title",
                defaultValue: "Allow notifications from \(displayOrigin)?"
            )
            alert.informativeText = String(
                localized: "browser.notifications.permission.message",
                defaultValue: "This website can send notifications through cmux. You can reset this decision by clearing the browser profile's data."
            )
            alert.addButton(withTitle: String(localized: "browser.notifications.permission.allow", defaultValue: "Allow"))
            alert.addButton(withTitle: String(localized: "browser.notifications.permission.deny", defaultValue: "Don't Allow"))
            let finish: (Bool, Bool) -> Void = { [weak self] allowed, shouldPersist in
                guard let self else { return }
                if shouldPersist {
                    repository.setDecision(allowed ? .allowed : .denied, for: origin, profileID: self.profileID)
                }
                let replies = self.pendingWebNotificationPermissionReplies.removeValue(forKey: originKey) ?? []
                for reply in replies { reply(allowed) }
            }
            webNotificationPermissionAlertPresenter(alert, webView, { response in
                let settingIsEnabled = SettingCatalog().browser.forwardWebNotifications.value(in: .standard)
                finish(settingIsEnabled && response == .alertFirstButtonReturn, settingIsEnabled)
            }, {
                finish(false, false)
            })
        }
    }

    private func webNotificationPermissionDecision(
        for rawOrigin: URL
    ) -> BrowserNotificationPermissionDecision {
        guard SettingCatalog().browser.forwardWebNotifications.value(in: .standard) else {
            return .denied
        }
        let repository = BrowserProfileStore.shared.notificationPermissions
        return storedWebNotificationPermissionDecision(
            for: rawOrigin,
            repository: repository
        )
    }

    private func storedWebNotificationPermissionDecision(
        for securityOrigin: URL,
        repository: BrowserNotificationPermissionRepository
    ) -> BrowserNotificationPermissionDecision {
        let displayOrigin = Self.remoteProxyDisplayURL(for: securityOrigin) ?? securityOrigin
        return repository.migrateDecisionIfNeeded(
            from: displayOrigin,
            to: securityOrigin,
            profileID: profileID
        )
    }

    /// Routes validated page content through the workspace notification policy.
    func handleWebNotificationPayload(
        _ payload: BrowserWebNotificationPayload,
        fromWebViewInstanceID instanceID: UUID
    ) {
        guard instanceID == webViewInstanceID else { return }
        let setting = SettingCatalog().browser.forwardWebNotifications
        guard setting.value(in: .standard) else { return }

        let rawOrigin = URL(string: "https://\(payload.hostname)")
        let displayHost = (Self.remoteProxyDisplayURL(for: rawOrigin) ?? rawOrigin)?.host ?? payload.hostname
        deliverWebNotification(workspaceId, id, payload.title, displayHost, payload.body)
    }

    /// Handles a foreground notification delivered by WebKit's native provider.
    func handleNativeWebNotification(title: String, body: String) {
        guard SettingCatalog().browser.forwardWebNotifications.value(in: .standard) else { return }
        let origin = Self.remoteProxyDisplayURL(for: webView.url) ?? webView.url
        deliverWebNotification(
            workspaceId,
            id,
            String(title.prefix(BrowserWebNotificationPayload.maximumTitleLength)),
            origin?.host ?? "",
            String(body.prefix(BrowserWebNotificationPayload.maximumBodyLength))
        )
    }
}
