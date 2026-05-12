import AppKit
import Combine
import CryptoKit
import Foundation
import WebKit

enum ExtensionBundleResolveError: Error, LocalizedError {
    case missingBundle(String)
    case missingIndex(String)

    var errorDescription: String? {
        switch self {
        case .missingBundle(let path):
            return "Extension bundle not found: \(path)"
        case .missingIndex(let path):
            return "Extension bundle must contain index.html: \(path)"
        }
    }
}

struct ExtensionBundleDescriptor: Equatable {
    let bundleURL: URL
    let indexURL: URL
    let displayName: String

    var bundlePath: String { bundleURL.path }

    static func resolve(path rawPath: String, fileManager: FileManager = .default) throws -> ExtensionBundleDescriptor {
        let expandedPath = (rawPath as NSString).expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expandedPath.isEmpty else {
            throw ExtensionBundleResolveError.missingBundle(rawPath)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else {
            throw ExtensionBundleResolveError.missingBundle(expandedPath)
        }

        let inputURL = URL(fileURLWithPath: expandedPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let bundleURL: URL
        let indexURL: URL
        if isDirectory.boolValue {
            bundleURL = inputURL
            indexURL = inputURL.appendingPathComponent("index.html", isDirectory: false)
        } else if inputURL.lastPathComponent == "index.html" {
            bundleURL = inputURL.deletingLastPathComponent()
            indexURL = inputURL
        } else {
            throw ExtensionBundleResolveError.missingIndex(inputURL.path)
        }

        var isIndexDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: indexURL.path, isDirectory: &isIndexDirectory),
              !isIndexDirectory.boolValue else {
            throw ExtensionBundleResolveError.missingIndex(bundleURL.path)
        }

        return ExtensionBundleDescriptor(
            bundleURL: bundleURL,
            indexURL: indexURL,
            displayName: Self.displayName(for: bundleURL)
        )
    }

    private static func displayName(for bundleURL: URL) -> String {
        let manifestURL = bundleURL.appendingPathComponent("manifest.json", isDirectory: false)
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = manifest["name"] as? String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        let folderName = bundleURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !folderName.isEmpty {
            return folderName
        }
        return String(localized: "extensionPanel.defaultTitle", defaultValue: "Extension")
    }
}

private struct ExtensionBridgeMessage {
    let id: Any
    let method: String
    let params: [String: Any]

    init?(body: [String: Any]) {
        guard let id = body["id"] else { return nil }
        guard let method = (body["method"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !method.isEmpty else { return nil }
        self.id = id
        self.method = method
        self.params = body["params"] as? [String: Any] ?? [:]
    }
}

private final class ExtensionBridgeMessageHandler: NSObject, WKScriptMessageHandler {
    private let onMessage: @MainActor (ExtensionBridgeMessage, WKWebView?) -> Void

    init(onMessage: @escaping @MainActor (ExtensionBridgeMessage, WKWebView?) -> Void) {
        self.onMessage = onMessage
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let bridgeMessage = ExtensionBridgeMessage(body: body) else {
            return
        }
        Task { @MainActor in
            onMessage(bridgeMessage, message.webView)
        }
    }
}

final class ExtensionWebView: WKWebView {
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }
}

final class ExtensionPanel: NSObject, Panel, ObservableObject {
    static let bridgeMessageHandlerName = "cmuxExtension"

    let id: UUID
    let panelType: PanelType = .extensionPane
    private(set) var workspaceId: UUID
    private(set) var paneId: UUID?
    let bundle: ExtensionBundleDescriptor

    @Published private(set) var pageTitle: String = ""
    @Published private(set) var isLoading: Bool = false

    private(set) var webView: ExtensionWebView
    private var webViewObservers: [NSKeyValueObservation] = []
    private var bridgeMessageHandler: ExtensionBridgeMessageHandler?
    private var eventSubscriptions: [String: CmuxEventSubscription] = [:]
    private var hasLoadedBundle = false

    var onRequestPanelFocus: (() -> Void)?

    var displayTitle: String {
        let trimmedPageTitle = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPageTitle.isEmpty ? bundle.displayName : trimmedPageTitle
    }

    var displayIcon: String? {
        "puzzlepiece.extension"
    }

    init(
        workspaceId: UUID,
        paneId: UUID?,
        bundle: ExtensionBundleDescriptor,
        autoLoad: Bool = true
    ) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.paneId = paneId
        self.bundle = bundle

        let configuration = WKWebViewConfiguration()
        Self.configureWebViewConfiguration(configuration, context: ExtensionPanel.contextPayload(
            workspaceId: workspaceId,
            surfaceId: id,
            paneId: paneId,
            bundle: bundle
        ))
        let webView = ExtensionWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        self.webView = webView

        super.init()

        let handler = ExtensionBridgeMessageHandler { [weak self] message, webView in
            self?.handleBridgeMessage(message, from: webView)
        }
        bridgeMessageHandler = handler
        configuration.userContentController.add(handler, name: Self.bridgeMessageHandlerName)
        webView.onMouseDown = { [weak self] in
            self?.onRequestPanelFocus?()
        }
        setupObservers(for: webView)

        if autoLoad {
            loadBundleIfNeeded()
        }
    }

    static func configureWebViewConfiguration(
        _ configuration: WKWebViewConfiguration,
        context: [String: Any]
    ) {
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(WKUserScript(
            source: bridgeBootstrapScript(context: context),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
    }

    func loadBundleIfNeeded() {
        guard !hasLoadedBundle else { return }
        hasLoadedBundle = true
        webView.loadFileURL(bundle.indexURL, allowingReadAccessTo: bundle.bundleURL)
    }

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
        syncBridgeContextToPage()
    }

    func updatePaneId(_ newPaneId: UUID?) {
        guard paneId != newPaneId else { return }
        paneId = newPaneId
        syncBridgeContextToPage()
    }

    func close() {
        closeEventSubscriptions()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeMessageHandlerName)
        webViewObservers.removeAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        bridgeMessageHandler = nil
        onRequestPanelFocus = nil
    }

    func focus() {
        guard let window = webView.window else { return }
        window.makeFirstResponder(webView)
    }

    func unfocus() {
        guard let window = webView.window,
              Self.responderChainContains(window.firstResponder, target: webView) else {
            return
        }
        window.makeFirstResponder(nil)
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }

    private func setupObservers(for webView: WKWebView) {
        let titleObserver = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                guard let self, webView === self.webView else { return }
                let trimmed = (webView.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard self.pageTitle != trimmed else { return }
                self.pageTitle = trimmed
            }
        }
        webViewObservers.append(titleObserver)

        let loadingObserver = webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, change in
            let isLoading = change.newValue ?? webView.isLoading
            Task { @MainActor in
                guard let self, webView === self.webView else { return }
                self.isLoading = isLoading
            }
        }
        webViewObservers.append(loadingObserver)
    }

    private func handleBridgeMessage(_ message: ExtensionBridgeMessage, from sourceWebView: WKWebView?) {
        guard sourceWebView == nil || sourceWebView === webView else { return }
        if message.method == "extension.events.subscribe" {
            completeBridgeMessage(id: message.id, response: subscribeToEvents(params: message.params))
            return
        }
        if message.method == "extension.events.unsubscribe" {
            completeBridgeMessage(id: message.id, response: unsubscribeFromEvents(params: message.params))
            return
        }
        if let response = handleKVMessage(method: message.method, params: message.params) {
            completeBridgeMessage(id: message.id, response: response)
            return
        }

        let response = TerminalController.shared.performExtensionBridgeRPC(
            method: message.method,
            params: message.params,
            workspaceId: workspaceId,
            surfaceId: id,
            paneId: paneId
        )
        completeBridgeMessage(id: message.id, response: response)
    }

    private func subscribeToEvents(params: [String: Any]) -> [String: Any] {
        let snapshot = CmuxEventBus.shared.subscribe(
            afterSequence: CmuxEventBus.int64(params["after_seq"] ?? params["after"]),
            names: Self.stringSet(params: params, singularKey: "name", pluralKey: "names"),
            categories: Self.stringSet(params: params, singularKey: "category", pluralKey: "categories")
        )
        let subscription = snapshot.subscription
        let subscriptionId = subscription.id.uuidString
        eventSubscriptions[subscriptionId] = subscription

        DispatchQueue.global(qos: .utility).async { [subscription, subscriptionId] in
            while !subscription.isClosed {
                guard let event = subscription.next(timeout: CmuxEventBus.defaultHeartbeatIntervalSeconds) else {
                    continue
                }
                DispatchQueue.main.async { [weak self] in
                    self?.dispatchEventSubscriptionMessage(subscriptionId: subscriptionId, event: event)
                }
            }
        }

        return [
            "ok": true,
            "result": [
                "subscription_id": subscriptionId,
                "ack": snapshot.ack,
                "replay": snapshot.replay
            ]
        ]
    }

    private func unsubscribeFromEvents(params: [String: Any]) -> [String: Any] {
        guard let subscriptionId = (params["subscription_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !subscriptionId.isEmpty else {
            return [
                "ok": false,
                "error": [
                    "code": "invalid_params",
                    "message": "Missing subscription_id",
                    "data": NSNull()
                ]
            ]
        }
        if let subscription = eventSubscriptions.removeValue(forKey: subscriptionId) {
            CmuxEventBus.shared.unsubscribe(subscription)
        }
        return [
            "ok": true,
            "result": ["subscription_id": subscriptionId]
        ]
    }

    private func closeEventSubscriptions() {
        for subscription in eventSubscriptions.values {
            CmuxEventBus.shared.unsubscribe(subscription)
        }
        eventSubscriptions.removeAll()
    }

    private func dispatchEventSubscriptionMessage(subscriptionId: String, event: [String: Any]) {
        guard eventSubscriptions[subscriptionId] != nil else { return }
        let subscriptionLiteral = Self.javaScriptLiteral(for: subscriptionId)
        let eventLiteral = Self.javaScriptLiteral(for: event)
        webView.evaluateJavaScript(
            "window.__cmuxExtensionBridgeDispatchEvent && window.__cmuxExtensionBridgeDispatchEvent(\(subscriptionLiteral), \(eventLiteral));",
            completionHandler: nil
        )
    }

    private func handleKVMessage(method: String, params: [String: Any]) -> [String: Any]? {
        switch method {
        case "extension.kv.get":
            guard let key = Self.kvKey(params) else {
                return Self.bridgeError(code: "invalid_params", message: "Missing key")
            }
            let value = Self.decodeJSONFragment(kvStore()[key]) ?? NSNull()
            return Self.bridgeOK(["key": key, "value": value])
        case "extension.kv.set":
            guard let key = Self.kvKey(params) else {
                return Self.bridgeError(code: "invalid_params", message: "Missing key")
            }
            guard let value = params["value"] else {
                return Self.bridgeError(code: "invalid_params", message: "Missing value")
            }
            guard let encoded = Self.encodeJSONFragment(value) else {
                return Self.bridgeError(code: "invalid_params", message: "Value must be JSON-serializable")
            }
            var store = kvStore()
            store[key] = encoded
            UserDefaults.standard.set(store, forKey: kvNamespaceDefaultsKey)
            return Self.bridgeOK(["key": key])
        case "extension.kv.remove":
            guard let key = Self.kvKey(params) else {
                return Self.bridgeError(code: "invalid_params", message: "Missing key")
            }
            var store = kvStore()
            store.removeValue(forKey: key)
            UserDefaults.standard.set(store, forKey: kvNamespaceDefaultsKey)
            return Self.bridgeOK(["key": key])
        case "extension.kv.keys":
            return Self.bridgeOK(["keys": kvStore().keys.sorted()])
        default:
            return nil
        }
    }

    private var kvNamespaceDefaultsKey: String {
        let digest = SHA256.hash(data: Data(bundle.bundlePath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "extensionPanel.kv.\(digest)"
    }

    private func kvStore() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: kvNamespaceDefaultsKey) as? [String: String] ?? [:]
    }

    private func completeBridgeMessage(id: Any, response: [String: Any]) {
        var envelope = response
        envelope["id"] = id
        let literal = Self.javaScriptLiteral(for: envelope)
        webView.evaluateJavaScript("window.__cmuxExtensionBridgeReceive && window.__cmuxExtensionBridgeReceive(\(literal));", completionHandler: nil)
    }

    private func syncBridgeContextToPage() {
        let literal = Self.javaScriptLiteral(for: Self.contextPayload(
            workspaceId: workspaceId,
            surfaceId: id,
            paneId: paneId,
            bundle: bundle
        ))
        webView.evaluateJavaScript("window.__cmuxExtensionBridgeUpdateContext && window.__cmuxExtensionBridgeUpdateContext(\(literal));", completionHandler: nil)
    }

    private static func contextPayload(
        workspaceId: UUID,
        surfaceId: UUID,
        paneId: UUID?,
        bundle: ExtensionBundleDescriptor
    ) -> [String: Any] {
        [
            "workspaceId": workspaceId.uuidString,
            "surfaceId": surfaceId.uuidString,
            "paneId": paneId?.uuidString as Any? ?? NSNull(),
            "bundlePath": bundle.bundlePath,
            "bundleName": bundle.displayName
        ]
    }

    private static func javaScriptLiteral(for object: Any) -> String {
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: []),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        let wrapped = [object]
        guard JSONSerialization.isValidJSONObject(wrapped),
              let data = try? JSONSerialization.data(withJSONObject: wrapped, options: []),
              let string = String(data: data, encoding: .utf8),
              string.count >= 2 else {
            return "null"
        }
        return String(string.dropFirst().dropLast())
    }

    private static func bridgeOK(_ result: Any) -> [String: Any] {
        [
            "ok": true,
            "result": result
        ]
    }

    private static func bridgeError(code: String, message: String, data: Any? = nil) -> [String: Any] {
        [
            "ok": false,
            "error": [
                "code": code,
                "message": message,
                "data": data ?? NSNull()
            ]
        ]
    }

    private static func kvKey(_ params: [String: Any]) -> String? {
        guard let key = (params["key"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !key.isEmpty else {
            return nil
        }
        return key
    }

    private static func encodeJSONFragment(_ value: Any) -> String? {
        let wrapped = [value]
        guard JSONSerialization.isValidJSONObject(wrapped),
              let data = try? JSONSerialization.data(withJSONObject: wrapped, options: []),
              let string = String(data: data, encoding: .utf8),
              string.count >= 2 else {
            return nil
        }
        return String(string.dropFirst().dropLast())
    }

    private static func decodeJSONFragment(_ value: String?) -> Any? {
        guard let value,
              let data = "[\(value)]".data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }
        return decoded.first ?? NSNull()
    }

    private static func bridgeBootstrapScript(context: [String: Any]) -> String {
        let contextLiteral = javaScriptLiteral(for: context)
        return """
        (() => {
          const initialContext = \(contextLiteral);
          if (window.__cmuxExtensionBridgeInstalled) {
            if (window.__cmuxExtensionBridgeUpdateContext) {
              window.__cmuxExtensionBridgeUpdateContext(initialContext);
            }
            return;
          }
          window.__cmuxExtensionBridgeInstalled = true;
          let nextRequestId = 1;
          const pending = new Map();
          const context = Object.assign({}, initialContext || {});
          const eventHandlers = new Map();

          const normalizeWorkspace = (params) => {
            const next = Object.assign({}, params || {});
            if (next.workspace && !next.workspace_id) next.workspace_id = next.workspace;
            delete next.workspace;
            if (!next.workspace_id && context.workspaceId) next.workspace_id = context.workspaceId;
            return next;
          };

          const normalizeSurface = (params) => {
            const next = normalizeWorkspace(params);
            if (next.surface && !next.surface_id) next.surface_id = next.surface;
            delete next.surface;
            return next;
          };

          const normalizePane = (params) => {
            const next = normalizeSurface(params);
            if (next.pane && !next.pane_id) next.pane_id = next.pane;
            delete next.pane;
            if (!next.pane_id && context.paneId) next.pane_id = context.paneId;
            return next;
          };

          const rpc = (method, params = {}) => new Promise((resolve, reject) => {
            const id = String(nextRequestId++);
            pending.set(id, { resolve, reject });
            window.webkit.messageHandlers.cmuxExtension.postMessage({ id, method, params });
          });

          window.__cmuxExtensionBridgeReceive = (message) => {
            const id = String(message && message.id);
            const entry = pending.get(id);
            if (!entry) return;
            pending.delete(id);
            if (message && message.ok) {
              entry.resolve(message.result);
              return;
            }
            const errorPayload = (message && message.error) || {};
            const error = new Error(errorPayload.message || "cmux bridge request failed");
            error.code = errorPayload.code || "bridge_error";
            error.data = errorPayload.data;
            entry.reject(error);
          };

          window.__cmuxExtensionBridgeUpdateContext = (next) => {
            Object.assign(context, next || {});
          };

          window.__cmuxExtensionBridgeDispatchEvent = (subscriptionId, event) => {
            const entry = eventHandlers.get(String(subscriptionId));
            if (!entry) return;
            entry.handler(event);
          };

          const cmux = {
            api: Object.freeze({ version: 1 }),
            get context() {
              return Object.freeze(Object.assign({}, context));
            },
            rpc,
            tree(params = {}) {
              return rpc("system.tree", normalizeWorkspace(params));
            },
            workspaces: Object.freeze({
              list(params = {}) {
                return rpc("workspace.list", normalizeWorkspace(params));
              },
              current(params = {}) {
                return rpc("workspace.current", normalizeWorkspace(params));
              }
            }),
            panes: Object.freeze({
              list(params = {}) {
                return rpc("pane.list", normalizeWorkspace(params));
              },
              surfaces(params = {}) {
                return rpc("pane.surfaces", normalizePane(params));
              }
            }),
            surfaces: Object.freeze({
              list(params = {}) {
                return rpc("surface.list", normalizeWorkspace(params));
              },
              current(params = {}) {
                return rpc("surface.current", normalizeWorkspace(params));
              },
              focus(params = {}) {
                return rpc("surface.focus", normalizeSurface(params));
              }
            }),
            send(params = {}) {
              return rpc("surface.send_text", normalizeSurface(params));
            },
            sendKey(params = {}) {
              return rpc("surface.send_key", normalizeSurface(params));
            },
            newPane(params = {}) {
              const next = normalizeSurface(params);
              if (!next.surface_id && context.surfaceId) next.surface_id = context.surfaceId;
              if (!next.direction) next.direction = "right";
              return rpc("pane.create", next);
            },
            newSurface(params = {}) {
              return rpc("surface.create", normalizePane(params));
            },
            events: Object.freeze({
              subscribe(params = {}, handler) {
                if (typeof params === "function") {
                  handler = params;
                  params = {};
                }
                return rpc("extension.events.subscribe", params || {}).then((subscription) => {
                  const id = String(subscription.subscription_id);
                  if (typeof handler === "function") {
                    eventHandlers.set(id, { handler });
                    for (const event of subscription.replay || []) {
                      Promise.resolve().then(() => handler(event));
                    }
                  }
                  return Object.freeze({
                    id,
                    ack: subscription.ack,
                    replay: subscription.replay || [],
                    unsubscribe() {
                      eventHandlers.delete(id);
                      return rpc("extension.events.unsubscribe", { subscription_id: id });
                    }
                  });
                });
              }
            }),
            kv: Object.freeze({
              get(key) {
                return rpc("extension.kv.get", { key }).then((result) => result.value);
              },
              set(key, value) {
                return rpc("extension.kv.set", { key, value });
              },
              remove(key) {
                return rpc("extension.kv.remove", { key });
              },
              keys() {
                return rpc("extension.kv.keys", {});
              }
            })
          };

          Object.defineProperty(window, "cmux", {
            value: Object.freeze(cmux),
            configurable: false,
            enumerable: true,
            writable: false
          });
        })();
        """
    }

    private static func responderChainContains(_ responder: NSResponder?, target: NSResponder) -> Bool {
        var current = responder
        while let candidate = current {
            if candidate === target { return true }
            current = candidate.nextResponder
        }
        return false
    }

    private static func stringSet(
        params: [String: Any],
        singularKey: String,
        pluralKey: String
    ) -> Set<String> {
        let rawValues: [Any]
        if let array = params[pluralKey] as? [Any] {
            rawValues = array
        } else if let array = params[singularKey] as? [Any] {
            rawValues = array
        } else if let value = params[pluralKey] {
            rawValues = [value]
        } else if let value = params[singularKey] {
            rawValues = [value]
        } else {
            rawValues = []
        }
        return Set(rawValues.compactMap { raw -> String? in
            guard let string = raw as? String else { return nil }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        })
    }
}
