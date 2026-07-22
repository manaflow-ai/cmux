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

func reactGrabRequestGenerationJavaScriptLiteral(_ generation: UInt64) -> String {
    "'\(generation)'"
}

func reactGrabActivationUpdaterInvocation(
    receiver: String,
    active: Bool,
    requestGeneration: UInt64
) -> String {
    let activeLiteral = active ? "true" : "false"
    return "\(receiver)(\(activeLiteral), " +
        reactGrabRequestGenerationJavaScriptLiteral(requestGeneration) + ")"
}

enum ReactGrabBridgeMessage {
    case stateChange(isActive: Bool, requestGeneration: UInt64? = nil)
    case copySuccess(content: String, token: String?)

    init?(body: [String: Any]) {
        let type = body["type"] as? String ?? "stateChange"
        switch type {
        case "stateChange":
            guard let isActive = body["isActive"] as? Bool else { return nil }
            let requestGeneration = (body["requestGeneration"] as? String).flatMap(UInt64.init)
            self = .stateChange(
                isActive: isActive,
                requestGeneration: requestGeneration
            )
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
        case .stateChange(let isActive, let requestGeneration):
            let generationDescription = requestGeneration.map(String.init) ?? "external"
            cmuxDebugLog(
                "reactGrab.messageHandler type=stateChange isActive=\(isActive) " +
                "generation=\(generationDescription)"
            )
        case .copySuccess(let content, _):
            cmuxDebugLog("reactGrab.messageHandler type=copySuccess len=\(content.count)")
        }
        #endif
        Task { @MainActor in
            #if DEBUG
            switch bridgeMessage {
            case .stateChange(let isActive, let requestGeneration):
                let generationDescription = requestGeneration.map(String.init) ?? "external"
                cmuxDebugLog(
                    "reactGrab.messageHandler.mainActor type=stateChange isActive=\(isActive) " +
                    "generation=\(generationDescription)"
                )
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
        case .stateChange(let isActive, let requestGeneration):
            if let requestGeneration {
                guard requestGeneration == reactGrabStateReconciliationGeneration,
                      latestReactGrabRequestedState == isActive else {
#if DEBUG
                    cmuxDebugLog(
                        "reactGrab.stateChange.drop state=\(isActive ? 1 : 0) " +
                        "generation=\(requestGeneration) " +
                        "current=\(reactGrabStateReconciliationGeneration)"
                    )
#endif
                    return
                }
            } else if let requestedReactGrabActive,
                      requestedReactGrabActive != isActive {
                // Unscoped callbacks include plugin initialization and direct
                // user interaction. While a request is pending, only its
                // target can confirm the transition.
                return
            }
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
    private func injectReactGrab(requestGeneration: UInt64) async -> Bool {
        #if DEBUG
        cmuxDebugLog("reactGrab.inject.start generation=\(requestGeneration)")
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
        let requestGenerationLiteral = reactGrabRequestGenerationJavaScriptLiteral(requestGeneration)
        let existingActivationUpdaterInvocation = reactGrabActivationUpdaterInvocation(
            receiver: "existingActivationUpdater",
            active: true,
            requestGeneration: requestGeneration
        )
        let fallbackActivationUpdaterInvocation = reactGrabActivationUpdaterInvocation(
            receiver: "window[activationUpdaterName]",
            active: true,
            requestGeneration: requestGeneration
        )
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
                return !!\(existingActivationUpdaterInvocation);
            }
            var apiReference = window.__REACT_GRAB__ || null;
            var desiredActive = true;
            var desiredRequestGeneration = \(requestGenerationLiteral);
            var pendingStateTransitions = [];
            var applyDesiredState = function() {
                if (!apiReference) return true;
                pendingStateTransitions.push({
                    active: desiredActive,
                    requestGeneration: desiredRequestGeneration
                });
                if (pendingStateTransitions.length > 16) {
                    pendingStateTransitions.splice(0, pendingStateTransitions.length - 16);
                }
                if (desiredActive) apiReference.activate();
                else apiReference.deactivate();
                return true;
            };
            var updateDesiredState = function(active, requestGeneration) {
                desiredActive = !!active;
                desiredRequestGeneration = String(requestGeneration || '');
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
                return !!\(fallbackActivationUpdaterInvocation);
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
                                if (handler) {
                                    var message = { type: 'stateChange', isActive: state.isActive };
                                    for (var i = pendingStateTransitions.length - 1; i >= 0; i--) {
                                        if (pendingStateTransitions[i].active === state.isActive) {
                                            message.requestGeneration = pendingStateTransitions[i].requestGeneration;
                                            pendingStateTransitions.splice(i, 1);
                                            break;
                                        }
                                    }
                                    handler.postMessage(message);
                                }
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

    /// Queues an idempotent requested state. Every explicit request supersedes
    /// the previous generation so an older script fetch, WebKit evaluation, or
    /// bridge confirmation cannot complete the newer request.
    @discardableResult
    func requestReactGrabActive(_ active: Bool, reason: String) -> Bool {
        guard !isClosingWebViewLifecycle else { return false }
        requestedReactGrabActive = active
        latestReactGrabRequestedState = active
        reactGrabStateReconciliationGeneration &+= 1
        let requestGeneration = reactGrabStateReconciliationGeneration
        reactGrabStateReconciliationTask?.cancel()
        reactGrabStateConfirmation?.cancel()
        reactGrabStateConfirmation = nil
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
        let requestGeneration = reactGrabStateReconciliationGeneration
        let reconciliationTask = reactGrabStateReconciliationTask
        await reconciliationTask?.value
        return !Task.isCancelled
            && !isClosingWebViewLifecycle
            && reactGrabStateReconciliationGeneration == requestGeneration
            && requestedReactGrabActive == nil
            && isReactGrabActive == active
    }

    private func reconcileReactGrabState(
        reason: String,
        requestGeneration: UInt64
    ) async {
        defer {
            if reactGrabStateReconciliationGeneration == requestGeneration {
                reactGrabStateReconciliationTask = nil
            }
        }

        guard let requested = requestedReactGrabActive,
              isCurrentReactGrabRequest(requested, generation: requestGeneration) else {
            return
        }
        let confirmed = await setReactGrabActive(
            requested,
            reason: reason,
            requestGeneration: requestGeneration
        )
        guard isCurrentReactGrabRequest(requested, generation: requestGeneration) else {
            return
        }
        requestedReactGrabActive = nil
        if requested, !confirmed {
            clearReactGrabRoundTrip(reason: "\(reason).confirmationFailed")
        }
    }

    private func isCurrentReactGrabRequest(_ active: Bool, generation: UInt64) -> Bool {
        !Task.isCancelled
            && !isClosingWebViewLifecycle
            && reactGrabStateReconciliationGeneration == generation
            && requestedReactGrabActive == active
    }

    @discardableResult
    private func setReactGrabActive(
        _ active: Bool,
        reason: String,
        requestGeneration: UInt64
    ) async -> Bool {
        guard isCurrentReactGrabRequest(active, generation: requestGeneration) else { return false }
        if active {
            guard await prepareForReactGrabActivation(reason: reason) else { return false }
            guard isCurrentReactGrabRequest(active, generation: requestGeneration) else { return false }
            if isReactGrabActive {
                guard pendingReactGrabRoundTripToken != nil else { return true }
                if await refreshReactGrabBridgeSessionToken() {
                    return isCurrentReactGrabRequest(active, generation: requestGeneration)
                }
                guard isCurrentReactGrabRequest(active, generation: requestGeneration) else { return false }
            }
        }

        guard isCurrentReactGrabRequest(active, generation: requestGeneration) else { return false }
        reactGrabStateConfirmation?.cancel()
        let confirmation = ReactGrabStateConfirmation(target: active)
        reactGrabStateConfirmation = confirmation

        let accepted: Bool
        if active {
            accepted = await injectReactGrab(requestGeneration: requestGeneration)
        } else {
            accepted = await requestReactGrabDeactivation(
                reason: reason,
                requestGeneration: requestGeneration
            )
        }
        guard accepted,
              isCurrentReactGrabRequest(active, generation: requestGeneration) else {
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
        guard isCurrentReactGrabRequest(active, generation: requestGeneration) else { return false }
        if confirmed, !active {
            clearReactGrabRoundTrip(reason: "\(reason).deactivate")
        }
        return confirmed
    }

    private func requestReactGrabDeactivation(
        reason: String,
        requestGeneration: UInt64
    ) async -> Bool {
        do {
            let updaterName = reactGrabBridgeActivationUpdaterName
            let deactivationUpdaterInvocation = reactGrabActivationUpdaterInvocation(
                receiver: "updateDesiredState",
                active: false,
                requestGeneration: requestGeneration
            )
            let result = try await evaluateJavaScript(
                """
                (function() {
                    var updateDesiredState = window['\(updaterName)'];
                    if (typeof updateDesiredState === 'function') {
                        return !!\(deactivationUpdaterInvocation);
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

    @discardableResult
    func toggleOrInjectReactGrab() async -> Bool {
        let desired = !reactGrabActivationIntent
        return await requestReactGrabActiveAndWait(desired, reason: "reactGrab.toggle")
    }

    @discardableResult
    func ensureReactGrabActive() async -> Bool {
        await requestReactGrabActiveAndWait(true, reason: "reactGrab.ensureActive")
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
        latestReactGrabRequestedState = nil
        isReactGrabActive = false
        if !preserveRoundTrip {
            clearReactGrabRoundTrip(reason: reason)
        }
    }
}
