import AppKit
import Combine
import Foundation
import WebKit

@MainActor
final class ExtensionPanel: NSObject, Panel, ObservableObject {
    static let bridgeMessageHandlerName = "cmuxExtension"
    private static let maxEventSubscriptions = 64

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
    private var eventSubscriptions: [String: (subscription: CmuxEventSubscription, handlerToken: UUID)] = [:]
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
        id: UUID = UUID(),
        workspaceId: UUID,
        paneId: UUID?,
        bundle: ExtensionBundleDescriptor,
        autoLoad: Bool = true
    ) {
        self.id = id
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

        webView.navigationDelegate = self
        let handler = ExtensionBridgeMessageHandler { [weak self] message, webView in
            self?.handleBridgeMessage(message, from: webView)
        }
        bridgeMessageHandler = handler
        webView.configuration.userContentController.add(handler, name: Self.bridgeMessageHandlerName)
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
            source: ExtensionBridgeJavaScript.bootstrapScript(context: context),
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
        guard workspaceId != newWorkspaceId else { return }
        workspaceId = newWorkspaceId
        updateBootstrapContextScript()
        syncBridgeContextToPage()
    }

    func updatePaneId(_ newPaneId: UUID?) {
        guard paneId != newPaneId else { return }
        paneId = newPaneId
        updateBootstrapContextScript()
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
            let isLoading = change.newValue ?? false
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

        let method = message.method
        guard let paramsFragment = ExtensionBridgeCodec.encodeJSONFragment(message.params),
              let messageIdFragment = ExtensionBridgeCodec.encodeJSONFragment(message.id) else {
            completeBridgeMessage(
                id: message.id,
                response: ExtensionBridgeCodec.bridgeError(
                    code: "invalid_params",
                    message: "Bridge message must contain JSON-serializable params and id"
                )
            )
            return
        }
        let workspaceId = workspaceId
        let surfaceId = id
        let paneId = paneId
        let terminalController = TerminalController.shared
        DispatchQueue.global(qos: .userInitiated).async { [terminalController, method, paramsFragment, messageIdFragment, workspaceId, surfaceId, paneId] in
            let params = ExtensionBridgeCodec.decodeJSONFragment(paramsFragment) as? [String: Any] ?? [:]
            let response = terminalController.performExtensionBridgeRPC(
                method: method,
                params: params,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                paneId: paneId
            )
            let messageId = ExtensionBridgeCodec.decodeJSONFragment(messageIdFragment) ?? NSNull()
            var envelope = response
            envelope["id"] = messageId
            let responseLiteral = ExtensionBridgeCodec.javaScriptLiteral(for: envelope)
            Task { @MainActor [weak self] in
                self?.completeBridgeMessageLiteral(responseLiteral)
            }
        }
    }

    private func subscribeToEvents(params: [String: Any]) -> [String: Any] {
        guard eventSubscriptions.count < Self.maxEventSubscriptions else {
            return ExtensionBridgeCodec.bridgeError(
                code: "too_many_subscriptions",
                message: "Extension exceeded maximum concurrent event subscriptions"
            )
        }

        let snapshot = CmuxEventBus.shared.subscribe(
            afterSequence: CmuxEventBus.int64(params["after_seq"] ?? params["after"]),
            names: Self.stringSet(params: params, singularKey: "name", pluralKey: "names"),
            categories: Self.stringSet(params: params, singularKey: "category", pluralKey: "categories")
        )
        let subscription = snapshot.subscription
        let subscriptionId = subscription.id.uuidString
        guard let handlerToken = subscription.addEventHandler({ [weak self] event in
            Task { @MainActor in
                self?.dispatchEventSubscriptionMessage(subscriptionId: subscriptionId, event: event)
            }
        }) else {
            CmuxEventBus.shared.unsubscribe(subscription)
            return ExtensionBridgeCodec.bridgeError(code: "subscription_closed", message: "Event subscription is already closed")
        }
        eventSubscriptions[subscriptionId] = (subscription: subscription, handlerToken: handlerToken)

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
        if let entry = eventSubscriptions.removeValue(forKey: subscriptionId) {
            entry.subscription.removeEventHandler(entry.handlerToken)
            CmuxEventBus.shared.unsubscribe(entry.subscription)
        }
        return [
            "ok": true,
            "result": ["subscription_id": subscriptionId]
        ]
    }

    private func closeEventSubscriptions() {
        for entry in eventSubscriptions.values {
            entry.subscription.removeEventHandler(entry.handlerToken)
            CmuxEventBus.shared.unsubscribe(entry.subscription)
        }
        eventSubscriptions.removeAll()
    }

    private func dispatchEventSubscriptionMessage(subscriptionId: String, event: [String: Any]) {
        guard eventSubscriptions[subscriptionId] != nil else { return }
        let subscriptionLiteral = ExtensionBridgeCodec.javaScriptLiteral(for: subscriptionId)
        let eventLiteral = ExtensionBridgeCodec.javaScriptLiteral(for: event)
        webView.evaluateJavaScript(
            "window.__cmuxExtensionBridgeDispatchEvent && window.__cmuxExtensionBridgeDispatchEvent(\(subscriptionLiteral), \(eventLiteral));",
            completionHandler: nil
        )
    }

    private func handleKVMessage(method: String, params: [String: Any]) -> [String: Any]? {
        switch method {
        case "extension.kv.get":
            guard let key = Self.kvKey(params) else {
                return ExtensionBridgeCodec.bridgeError(code: "invalid_params", message: "Missing key")
            }
            let value = ExtensionKVStore(bundle: bundle, workspaceId: workspaceId.uuidString).get(key)
            return ExtensionBridgeCodec.bridgeOK(["key": key, "value": value])
        case "extension.kv.set":
            guard let key = Self.kvKey(params) else {
                return ExtensionBridgeCodec.bridgeError(code: "invalid_params", message: "Missing key")
            }
            guard let value = params["value"] else {
                return ExtensionBridgeCodec.bridgeError(code: "invalid_params", message: "Missing value")
            }
            guard let encoded = ExtensionBridgeCodec.encodeJSONFragment(value) else {
                return ExtensionBridgeCodec.bridgeError(code: "invalid_params", message: "Value must be JSON-serializable")
            }
            switch ExtensionKVStore(bundle: bundle, workspaceId: workspaceId.uuidString).set(key: key, encodedValue: encoded) {
            case .success:
                return ExtensionBridgeCodec.bridgeOK(["key": key])
            case .failure(let error):
                return ExtensionBridgeCodec.bridgeError(code: error.bridgeCode, message: error.message)
            }
        case "extension.kv.remove":
            guard let key = Self.kvKey(params) else {
                return ExtensionBridgeCodec.bridgeError(code: "invalid_params", message: "Missing key")
            }
            ExtensionKVStore(bundle: bundle, workspaceId: workspaceId.uuidString).remove(key)
            return ExtensionBridgeCodec.bridgeOK(["key": key])
        case "extension.kv.keys":
            return ExtensionBridgeCodec.bridgeOK(["keys": ExtensionKVStore(bundle: bundle, workspaceId: workspaceId.uuidString).keys()])
        default:
            return nil
        }
    }

    private func completeBridgeMessage(id: Any, response: [String: Any]) {
        var envelope = response
        envelope["id"] = id
        let literal = ExtensionBridgeCodec.javaScriptLiteral(for: envelope)
        completeBridgeMessageLiteral(literal)
    }

    private func completeBridgeMessageLiteral(_ literal: String) {
        webView.evaluateJavaScript("window.__cmuxExtensionBridgeReceive && window.__cmuxExtensionBridgeReceive(\(literal));", completionHandler: nil)
    }

    private func updateBootstrapContextScript() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(
            source: ExtensionBridgeJavaScript.bootstrapScript(context: currentContextPayload()),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
    }

    private func syncBridgeContextToPage() {
        let literal = ExtensionBridgeCodec.javaScriptLiteral(for: currentContextPayload())
        webView.evaluateJavaScript("window.__cmuxExtensionBridgeUpdateContext && window.__cmuxExtensionBridgeUpdateContext(\(literal));", completionHandler: nil)
    }

    private func currentContextPayload() -> [String: Any] {
        Self.contextPayload(
            workspaceId: workspaceId,
            surfaceId: id,
            paneId: paneId,
            bundle: bundle
        )
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

    private static func kvKey(_ params: [String: Any]) -> String? {
        guard let key = (params["key"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !key.isEmpty else {
            return nil
        }
        return key
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

extension ExtensionPanel: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame == true else {
            decisionHandler(.allow)
            return
        }

        guard isAllowedMainFrameNavigationURL(navigationAction.request.url) else {
            decisionHandler(.cancel)
            return
        }

        closeEventSubscriptions()
        decisionHandler(.allow)
    }

    private func isAllowedMainFrameNavigationURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.scheme?.lowercased() == "about", url.absoluteString == "about:blank" {
            return true
        }
        guard url.isFileURL else { return false }
        let canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let bundlePath = bundle.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        return canonicalPath == bundlePath || canonicalPath.hasPrefix(bundlePath + "/")
    }
}

@MainActor
final class BlockedExtensionPanel: Panel, ObservableObject {
    enum State: Equatable {
        case verifying
        case blocked(String)
    }

    let id: UUID
    let panelType: PanelType = .extensionPane
    let bundlePath: String
    private(set) var workspaceId: UUID
    private(set) var paneId: UUID?
    @Published private(set) var state: State

    init(
        id: UUID = UUID(),
        workspaceId: UUID,
        paneId: UUID?,
        bundlePath: String,
        state: State
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.paneId = paneId
        self.bundlePath = bundlePath
        self.state = state
    }

    var displayTitle: String {
        let folderName = (bundlePath as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !folderName.isEmpty {
            return folderName
        }
        return String(localized: "extensionPanel.defaultTitle", defaultValue: "Extension")
    }

    var displayIcon: String? {
        switch state {
        case .verifying:
            return "puzzlepiece.extension"
        case .blocked:
            return "exclamationmark.triangle"
        }
    }

    var isLoading: Bool {
        if case .verifying = state {
            return true
        }
        return false
    }

    var statusTitle: String {
        switch state {
        case .verifying:
            return String(localized: "extensionPanel.restore.verifying.title", defaultValue: "Checking Extension")
        case .blocked:
            return String(localized: "extensionPanel.restore.blocked.title", defaultValue: "Extension Unavailable")
        }
    }

    var statusMessage: String {
        switch state {
        case .verifying:
            return String(
                localized: "extensionPanel.restore.verifying.message",
                defaultValue: "cmux is verifying this extension bundle before restoring it."
            )
        case .blocked(let reason):
            return reason
        }
    }

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
    }

    func updatePaneId(_ newPaneId: UUID?) {
        paneId = newPaneId
    }

    func markBlocked(_ reason: String) {
        state = .blocked(reason)
    }

    func close() {}

    func focus() {}

    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}
