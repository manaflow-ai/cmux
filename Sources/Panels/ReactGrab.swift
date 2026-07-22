import CryptoKit
import Foundation
import WebKit

#if DEBUG
import Bonsplit
#endif

// MARK: - Settings

enum ReactGrabSettings {
    static let versionKey = "reactGrabVersion"
    static let defaultVersion = "0.1.29"

    /// Known versions and their SHA-256 integrity hashes.
    /// Add new entries when bumping the default or to allow user-selected versions.
    static let knownHashes: [String: String] = [
        "0.1.29": "4a1e71090e8ad8bb6049de80ccccdc0f5bb147b9f8fb88886d871612ac7ca04b",
    ]

    static func scriptURL(for version: String) -> URL {
        URL(string: "https://unpkg.com/react-grab@\(version)/dist/index.global.js")!
    }

    static var configuredVersion: String {
        let stored = UserDefaults.standard.string(forKey: versionKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultVersion : stored
    }
}

struct ReactGrabShortcutPanelSnapshot: Equatable {
    let id: UUID
    let panelType: PanelType
    let isFocused: Bool
}

struct ReactGrabShortcutRoute: Equatable {
    let browserPanelId: UUID
    let returnTerminalPanelId: UUID?
}

func resolveReactGrabShortcutRoute(
    panels: [ReactGrabShortcutPanelSnapshot]
) -> ReactGrabShortcutRoute? {
    guard let focusedPanel = panels.first(where: \.isFocused) else { return nil }

    if focusedPanel.panelType == .browser {
        return ReactGrabShortcutRoute(
            browserPanelId: focusedPanel.id,
            returnTerminalPanelId: nil
        )
    }

    guard focusedPanel.panelType == .terminal else { return nil }

    let browserPanels = panels.filter { $0.panelType == .browser }
    guard browserPanels.count == 1, let browserPanel = browserPanels.first else {
        return nil
    }

    return ReactGrabShortcutRoute(
        browserPanelId: browserPanel.id,
        returnTerminalPanelId: focusedPanel.id
    )
}

enum ReactGrabPastebackNotificationKey {
    static let workspaceId = "workspaceId"
    static let browserPanelId = "browserPanelId"
    static let returnPanelId = "returnPanelId"
    static let content = "content"
}

private enum ReactGrabPastebackContentFilter {
    private static let dangerousScalars: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
        "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
        "\u{FEFF}",
    ]

    static func filtered(_ text: String) -> String {
        String(text.unicodeScalars.filter { !dangerousScalars.contains($0) })
    }
}

// MARK: - Script Loader

/// Fetches, integrity-checks, and caches the react-grab script.
/// Shared across all BrowserPanel instances.
enum ReactGrabScriptLoader {
    private static var cachedScript: String?
    private static var cachedVersion: String?
    private static var prefetchTask: Task<String?, Never>?

    static func prefetch() {
        let version = ReactGrabSettings.configuredVersion
        // Invalidate cache if version changed.
        if cachedVersion != version {
            cachedScript = nil
            cachedVersion = nil
        }
        guard cachedScript == nil else { return }
        guard prefetchTask == nil else { return }
        prefetchTask = Task.detached(priority: .low) {
            let result = await doFetch(version: version)
            await MainActor.run { prefetchTask = nil }
            return result
        }
    }

    static func fetch() async -> String? {
        let version = ReactGrabSettings.configuredVersion
        if cachedVersion == version, let cached = cachedScript { return cached }
        prefetch()
        return await prefetchTask?.value
    }

    private static func doFetch(version: String) async -> String? {
        let url = ReactGrabSettings.scriptURL(for: version)
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let expectedHash = ReactGrabSettings.knownHashes[version] {
                let hash = SHA256.hash(data: data)
                let hex = hash.compactMap { String(format: "%02x", $0) }.joined()
                guard hex == expectedHash else {
                    NSLog("ReactGrab: integrity mismatch for v%@ (got %@)", version, hex)
                    return nil
                }
            }
            guard let script = String(data: data, encoding: .utf8) else { return nil }
            await MainActor.run {
                cachedScript = script
                cachedVersion = version
            }
            return script
        } catch {
            NSLog("ReactGrab: fetch failed for v%@: %@", version, error.localizedDescription)
            return nil
        }
    }
}

// MARK: - WKScriptMessageHandler

private let reactGrabMessageHandlerName = "cmuxReactGrab"

enum ReactGrabBridgeMessage {
    case stateChange(isActive: Bool)
    case copySuccess(content: String, token: String?)

    init?(body: [String: Any]) {
        let type = body["type"] as? String ?? "stateChange"
        switch type {
        case "stateChange":
            guard let isActive = body["isActive"] as? Bool else { return nil }
            self = .stateChange(isActive: isActive)
        case "copySuccess":
            guard let content = body["content"] as? String else { return nil }
            self = .copySuccess(content: content, token: body["token"] as? String)
        default:
            return nil
        }
    }
}

/// One bridge-confirmed React Grab state transition. JavaScript evaluation
/// only proves that a request was issued; this waiter completes from the
/// plugin's structured `stateChange` callback or a bounded timeout.
@MainActor
final class ReactGrabStateConfirmation {
    let target: Bool
    private let stream: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    init(target: Bool) {
        self.target = target
        let pair = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream
        continuation = pair.continuation
    }

    func receive(_ state: Bool) {
        guard state == target else { return }
        continuation.yield(true)
        continuation.finish()
    }

    func cancel() {
        continuation.yield(false)
        continuation.finish()
    }

    func wait(timeout: Duration = .seconds(3)) async -> Bool {
        let stream = stream
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await confirmed in stream { return confirmed }
                return false
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return false
                } catch {
                    return false
                }
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

class ReactGrabMessageHandler: NSObject, WKScriptMessageHandler {
    private let onMessage: @MainActor (ReactGrabBridgeMessage) -> Void

    init(onMessage: @escaping @MainActor (ReactGrabBridgeMessage) -> Void) {
        self.onMessage = onMessage
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let bridgeMessage = ReactGrabBridgeMessage(body: body) else { return }
        #if DEBUG
        switch bridgeMessage {
        case .stateChange(let isActive):
            cmuxDebugLog("reactGrab.messageHandler type=stateChange isActive=\(isActive)")
        case .copySuccess(let content, _):
            cmuxDebugLog("reactGrab.messageHandler type=copySuccess len=\(content.count)")
        }
        #endif
        Task { @MainActor in
            #if DEBUG
            switch bridgeMessage {
            case .stateChange(let isActive):
                cmuxDebugLog("reactGrab.messageHandler.mainActor type=stateChange isActive=\(isActive)")
            case .copySuccess(let content, _):
                cmuxDebugLog("reactGrab.messageHandler.mainActor type=copySuccess len=\(content.count)")
            }
            #endif
            onMessage(bridgeMessage)
        }
    }
}

// MARK: - BrowserPanel extension

extension BrowserPanel {
    private func reactGrabSessionTokenLiteral() -> String {
        pendingReactGrabRoundTripToken.map { "'\($0)'" } ?? "null"
    }

    private func reactGrabBridgeSessionRefreshScript() -> String {
        """
        (function() {
            var syncToken = window['\(reactGrabBridgeSessionUpdaterName)'];
            if (typeof syncToken !== 'function') {
                return false;
            }
            return !!syncToken(\(reactGrabSessionTokenLiteral()));
        })();
        """
    }

    func setupReactGrabMessageHandler(for webView: WKWebView) {
        let boundWebViewInstanceID = webViewInstanceID
        let handler = ReactGrabMessageHandler { [weak self, weak webView] message in
            guard let self,
                  let webView,
                  !self.isClosingWebViewLifecycle,
                  self.webView === webView,
                  self.webViewInstanceID == boundWebViewInstanceID else {
                return
            }
            self.handleReactGrabBridgeMessage(message)
        }
        reactGrabMessageHandler = handler
        webView.configuration.userContentController.add(handler, name: reactGrabMessageHandlerName)
    }

    func armReactGrabRoundTrip(returnTo panelId: UUID) {
        let token = UUID().uuidString
#if DEBUG
        cmuxDebugLog(
            "reactGrab.pasteback h3.arm " +
            "workspace=\(workspaceId.uuidString.prefix(5)) " +
            "browser=\(id.uuidString.prefix(5)) " +
            "return=\(panelId.uuidString.prefix(5))"
        )
#endif
        pendingReactGrabReturnTargetPanelId = panelId
        pendingReactGrabRoundTripToken = token
    }

    func clearReactGrabRoundTrip(reason: String = "unspecified") {
#if DEBUG
        let previousTarget = pendingReactGrabReturnTargetPanelId.map {
            String($0.uuidString.prefix(5))
        } ?? "nil"
        cmuxDebugLog(
            "reactGrab.pasteback h3.clear " +
            "workspace=\(workspaceId.uuidString.prefix(5)) " +
            "browser=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) previous=\(previousTarget)"
        )
#endif
        pendingReactGrabReturnTargetPanelId = nil
        pendingReactGrabRoundTripToken = nil
    }

    func handleReactGrabBridgeMessage(_ message: ReactGrabBridgeMessage) {
        switch message {
        case .stateChange(let isActive):
            isReactGrabActive = isActive
            reactGrabStateConfirmation?.receive(isActive)
#if DEBUG
            let pendingTarget = pendingReactGrabReturnTargetPanelId.map {
                String($0.uuidString.prefix(5))
            } ?? "nil"
            cmuxDebugLog(
                "reactGrab.pasteback h3.stateChange " +
                "workspace=\(workspaceId.uuidString.prefix(5)) " +
                "browser=\(id.uuidString.prefix(5)) " +
                "isActive=\(isActive ? 1 : 0) pending=\(pendingTarget)"
            )
#endif
        case .copySuccess(let content, let token):
            guard let returnPanelId = pendingReactGrabReturnTargetPanelId,
                  let expectedToken = pendingReactGrabRoundTripToken else {
#if DEBUG
                cmuxDebugLog(
                    "reactGrab.pasteback h3.copySuccess.drop " +
                    "workspace=\(workspaceId.uuidString.prefix(5)) " +
                    "browser=\(id.uuidString.prefix(5)) reason=noReturnTarget len=\(content.count)"
                )
#endif
                return
            }
            guard token == expectedToken else {
#if DEBUG
                cmuxDebugLog(
                    "reactGrab.pasteback h3.copySuccess.drop " +
                    "workspace=\(workspaceId.uuidString.prefix(5)) " +
                    "browser=\(id.uuidString.prefix(5)) reason=tokenMismatch len=\(content.count)"
                )
#endif
                clearReactGrabRoundTrip(reason: "copySuccess.tokenMismatch")
                return
            }
#if DEBUG
            cmuxDebugLog(
                "reactGrab.pasteback h3.copySuccess " +
                "workspace=\(workspaceId.uuidString.prefix(5)) " +
                "browser=\(id.uuidString.prefix(5)) " +
                "return=\(returnPanelId.uuidString.prefix(5)) len=\(content.count)"
            )
#endif
            let filteredContent = ReactGrabPastebackContentFilter.filtered(content)
            clearReactGrabRoundTrip(reason: "copySuccess")
            NotificationCenter.default.post(
                name: .reactGrabDidCopySelection,
                object: nil,
                userInfo: [
                    ReactGrabPastebackNotificationKey.workspaceId: workspaceId,
                    ReactGrabPastebackNotificationKey.browserPanelId: id,
                    ReactGrabPastebackNotificationKey.returnPanelId: returnPanelId,
                    ReactGrabPastebackNotificationKey.content: filteredContent,
                ]
            )
        }
    }

    @discardableResult
    private func injectReactGrab() async -> Bool {
        #if DEBUG
        cmuxDebugLog("reactGrab.inject.start")
        #endif
        guard let scriptSource = await ReactGrabScriptLoader.fetch() else {
            #if DEBUG
            cmuxDebugLog("reactGrab.inject.fetchFailed")
            #endif
            return false
        }
        guard !Task.isCancelled, !isClosingWebViewLifecycle else { return false }
        #if DEBUG
        cmuxDebugLog("reactGrab.inject.fetched len=\(scriptSource.count)")
        #endif

        let handlerName = reactGrabMessageHandlerName
        let sessionTokenLiteral = reactGrabSessionTokenLiteral()
        let activationUpdaterName = reactGrabBridgeActivationUpdaterName
        let combined = """
        (function() {
            var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
            var updaterName = '\(reactGrabBridgeSessionUpdaterName)';
            var activationUpdaterName = '\(activationUpdaterName)';
            var refreshSessionToken = function() {
                var syncToken = window[updaterName];
                if (typeof syncToken !== 'function') return false;
                return !!syncToken(\(sessionTokenLiteral));
            };
            var existingActivationUpdater = window[activationUpdaterName];
            if (typeof existingActivationUpdater === 'function') {
                refreshSessionToken();
                return !!existingActivationUpdater(true);
            }
            var apiReference = window.__REACT_GRAB__ || null;
            var desiredActive = true;
            var applyDesiredState = function() {
                if (!apiReference) return true;
                if (desiredActive) apiReference.activate();
                else apiReference.deactivate();
                return true;
            };
            var updateDesiredState = function(active) {
                desiredActive = !!active;
                return applyDesiredState();
            };
            try {
                Object.defineProperty(window, activationUpdaterName, {
                    value: updateDesiredState,
                    writable: false,
                    configurable: false,
                    enumerable: false
                });
            } catch (_) {
                if (typeof window[activationUpdaterName] !== 'function') return false;
                return !!window[activationUpdaterName](true);
            }
            var installBridge = function(api) {
                if (!api) return false;
                apiReference = api;
                if (!window.__CMUX_REACT_GRAB_BRIDGE_INSTALLED__) {
                    window.__CMUX_REACT_GRAB_BRIDGE_INSTALLED__ = true;
                    var activeToken = null;
                    var syncSessionToken = function(token) {
                        activeToken = (typeof token === 'string' && token.length > 0) ? token : null;
                        return true;
                    };
                    try {
                        Object.defineProperty(window, updaterName, {
                            value: syncSessionToken,
                            writable: false,
                            configurable: false,
                            enumerable: false
                        });
                    } catch (_) {
                        if (typeof window[updaterName] !== 'function') return false;
                    }
                    api.registerPlugin({
                        name: 'cmux-bridge',
                        hooks: {
                            onStateChange: function(state) {
                                if (handler) handler.postMessage({ type: 'stateChange', isActive: state.isActive });
                            },
                            onCopySuccess: function(elements, content) {
                                var token = activeToken;
                                activeToken = null;
                                if (handler) handler.postMessage({ type: 'copySuccess', content: String(content || ''), token: token });
                            }
                        }
                    });
                }
                refreshSessionToken();
                return applyDesiredState();
            }
            if (window.__REACT_GRAB__) {
                return installBridge(window.__REACT_GRAB__);
            }
            window.addEventListener('react-grab:init', function(e) {
                var api = e.detail;
                if (!api) return;
                installBridge(api);
            }, { once: true });
            return true;
        })();
        \(scriptSource)
        """
        #if DEBUG
        cmuxDebugLog("reactGrab.inject.evalJS len=\(combined.count)")
        #endif
        do {
            _ = try await evaluateJavaScript(combined)
            guard !Task.isCancelled, !isClosingWebViewLifecycle else { return false }
            #if DEBUG
            cmuxDebugLog("reactGrab.inject.evalJS.done error=none")
            #endif
            #if DEBUG
            cmuxDebugLog("reactGrab.inject.end")
            #endif
            return true
        } catch {
            #if DEBUG
            cmuxDebugLog("reactGrab.inject.evalJS.done error=\(error.localizedDescription)")
            #endif
            NSLog("ReactGrab: injection failed: %@", error.localizedDescription)
            return false
        }
    }

    var reactGrabActivationIntent: Bool {
        requestedReactGrabActive ?? isReactGrabActive
    }

    /// Queues an idempotent requested state. A single reconciliation task
    /// serializes requests so a later explicit state cannot be overtaken by an
    /// earlier script fetch or WebKit evaluation.
    @discardableResult
    func requestReactGrabActive(_ active: Bool, reason: String) -> Bool {
        guard !isClosingWebViewLifecycle else { return false }
        requestedReactGrabActive = active
        reactGrabStateConfirmation?.cancel()
        reactGrabStateConfirmation = nil
        guard reactGrabStateReconciliationTask == nil else { return true }
        reactGrabStateReconciliationGeneration &+= 1
        let requestGeneration = reactGrabStateReconciliationGeneration
        reactGrabStateReconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconcileReactGrabState(
                reason: reason,
                requestGeneration: requestGeneration
            )
        }
        return true
    }

    /// Requests a state through the serialized reconciler and waits for the
    /// same bridge confirmation used by automation. Design Mode uses this to
    /// avoid racing a pending React Grab transition.
    func requestReactGrabActiveAndWait(_ active: Bool, reason: String) async -> Bool {
        guard requestReactGrabActive(active, reason: reason) else { return false }
        let reconciliationTask = reactGrabStateReconciliationTask
        await reconciliationTask?.value
        return !Task.isCancelled
            && !isClosingWebViewLifecycle
            && requestedReactGrabActive == nil
            && isReactGrabActive == active
    }

    private func reconcileReactGrabState(
        reason: String,
        requestGeneration: UInt64
    ) async {
        while !Task.isCancelled,
              !isClosingWebViewLifecycle,
              reactGrabStateReconciliationGeneration == requestGeneration,
              let requested = requestedReactGrabActive {
            let confirmed = await setReactGrabActive(requested, reason: reason)
            guard !Task.isCancelled,
                  !isClosingWebViewLifecycle,
                  reactGrabStateReconciliationGeneration == requestGeneration else {
                break
            }
            if requestedReactGrabActive == requested {
                requestedReactGrabActive = nil
                if requested, !confirmed {
                    clearReactGrabRoundTrip(reason: "\(reason).confirmationFailed")
                }
            }
        }
        if reactGrabStateReconciliationGeneration == requestGeneration {
            reactGrabStateReconciliationTask = nil
        }
    }

    @discardableResult
    private func setReactGrabActive(_ active: Bool, reason: String) async -> Bool {
        guard !Task.isCancelled, !isClosingWebViewLifecycle else { return false }
        if active {
            guard await prepareForReactGrabActivation(reason: reason) else { return false }
            guard !Task.isCancelled, !isClosingWebViewLifecycle else { return false }
            if isReactGrabActive {
                guard pendingReactGrabRoundTripToken != nil else { return true }
                if await refreshReactGrabBridgeSessionToken() {
                    return !Task.isCancelled && !isClosingWebViewLifecycle
                }
                guard !Task.isCancelled, !isClosingWebViewLifecycle else { return false }
            }
        }

        reactGrabStateConfirmation?.cancel()
        let confirmation = ReactGrabStateConfirmation(target: active)
        reactGrabStateConfirmation = confirmation

        let accepted: Bool
        if active {
            accepted = await injectReactGrab()
        } else {
            accepted = await requestReactGrabDeactivation(reason: reason)
        }
        guard accepted,
              !Task.isCancelled,
              !isClosingWebViewLifecycle else {
            if reactGrabStateConfirmation === confirmation {
                reactGrabStateConfirmation = nil
            }
            confirmation.cancel()
            return false
        }

        // The bridge callback may have arrived synchronously during script
        // evaluation. Otherwise this preserves the requested intent until the
        // authoritative state callback or the bounded timeout.
        if isReactGrabActive == active {
            confirmation.receive(active)
        }
        let confirmed = await confirmation.wait()
        if reactGrabStateConfirmation === confirmation {
            reactGrabStateConfirmation = nil
        }
        confirmation.cancel()
        if confirmed, !active {
            clearReactGrabRoundTrip(reason: "\(reason).deactivate")
        }
        return confirmed
    }

    private func requestReactGrabDeactivation(reason: String) async -> Bool {
        do {
            let updaterName = reactGrabBridgeActivationUpdaterName
            let result = try await evaluateJavaScript(
                """
                (function() {
                    var updateDesiredState = window['\(updaterName)'];
                    if (typeof updateDesiredState === 'function') {
                        return !!updateDesiredState(false);
                    }
                    var api = window.__REACT_GRAB__;
                    if (!api) return true;
                    api.deactivate();
                    return true;
                })();
                """
            )
            guard !Task.isCancelled, !isClosingWebViewLifecycle else { return false }
            return (result as? Bool) ?? false
        } catch {
#if DEBUG
            cmuxDebugLog("reactGrab.deactivate.error reason=\(reason) error=\(error.localizedDescription)")
#endif
            return false
        }
    }

    func toggleOrInjectReactGrab() async {
        let desired = !reactGrabActivationIntent
        _ = requestReactGrabActive(desired, reason: "reactGrab.toggle")
    }

    func ensureReactGrabActive() async {
        _ = requestReactGrabActive(true, reason: "reactGrab.ensureActive")
    }

    @discardableResult
    func refreshReactGrabBridgeSessionToken() async -> Bool {
        do {
            let result = try await evaluateJavaScript(reactGrabBridgeSessionRefreshScript())
            return (result as? Bool) ?? false
        } catch {
#if DEBUG
            cmuxDebugLog("reactGrab.bridgeSessionRefresh.error error=\(error.localizedDescription)")
#endif
            return false
        }
    }

    func resetReactGrabState(
        preserveRoundTrip: Bool = false,
        reason: String = "unspecified"
    ) {
#if DEBUG
        let pendingTarget = pendingReactGrabReturnTargetPanelId.map {
            String($0.uuidString.prefix(5))
        } ?? "nil"
        cmuxDebugLog(
            "reactGrab.pasteback h3.reset " +
            "workspace=\(workspaceId.uuidString.prefix(5)) " +
            "browser=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) preserve=\(preserveRoundTrip ? 1 : 0) " +
            "pending=\(pendingTarget) active=\(isReactGrabActive ? 1 : 0)"
        )
#endif
        reactGrabStateReconciliationGeneration &+= 1
        reactGrabStateReconciliationTask?.cancel()
        reactGrabStateReconciliationTask = nil
        reactGrabStateConfirmation?.cancel()
        reactGrabStateConfirmation = nil
        requestedReactGrabActive = nil
        isReactGrabActive = false
        if !preserveRoundTrip {
            clearReactGrabRoundTrip(reason: reason)
        }
    }
}
