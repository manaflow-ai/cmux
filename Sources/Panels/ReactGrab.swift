import Foundation
import WebKit

#if DEBUG
import Bonsplit
#endif

// MARK: - Settings

enum ReactGrabSettings {
    static let versionKey = "reactGrabVersion"

    /// Built from https://github.com/aidenybai/react-grab (v0.1.31) with
    /// PREVIEW_TEXT_MAX_LENGTH increased to 50000 so element text is not
    /// truncated to 100 chars.
    static let defaultVersion = "0.1.31"
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

/// Loads the bundled react-grab script from app resources.
/// Shared across all BrowserPanel instances.
enum ReactGrabScriptLoader {
    private static var cachedScript: String?

    static func prefetch() {
        guard cachedScript == nil else { return }
        cachedScript = loadFromBundle()
    }

    static func fetch() async -> String? {
        if let cached = cachedScript { return cached }
        let script = loadFromBundle()
        cachedScript = script
        return script
    }

    private static func loadFromBundle() -> String? {
        guard let url = Bundle.main.url(forResource: "react-grab", withExtension: "js") else {
            NSLog("ReactGrab: react-grab.js not found in bundle")
            return nil
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            NSLog("ReactGrab: failed to read bundled script: %@", error.localizedDescription)
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
            dlog("reactGrab.messageHandler type=stateChange isActive=\(isActive)")
        case .copySuccess(let content, _):
            dlog("reactGrab.messageHandler type=copySuccess len=\(content.count)")
        }
        #endif
        Task { @MainActor in
            #if DEBUG
            switch bridgeMessage {
            case .stateChange(let isActive):
                dlog("reactGrab.messageHandler.mainActor type=stateChange isActive=\(isActive)")
            case .copySuccess(let content, _):
                dlog("reactGrab.messageHandler.mainActor type=copySuccess len=\(content.count)")
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
        let handler = ReactGrabMessageHandler { [weak self] message in
            self?.handleReactGrabBridgeMessage(message)
        }
        reactGrabMessageHandler = handler
        webView.configuration.userContentController.add(handler, name: reactGrabMessageHandlerName)
    }

    func armReactGrabRoundTrip(returnTo panelId: UUID) {
        let token = UUID().uuidString
#if DEBUG
        dlog(
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
        dlog(
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
#if DEBUG
            let pendingTarget = pendingReactGrabReturnTargetPanelId.map {
                String($0.uuidString.prefix(5))
            } ?? "nil"
            dlog(
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
                dlog(
                    "reactGrab.pasteback h3.copySuccess.drop " +
                    "workspace=\(workspaceId.uuidString.prefix(5)) " +
                    "browser=\(id.uuidString.prefix(5)) reason=noReturnTarget len=\(content.count)"
                )
#endif
                return
            }
            guard token == expectedToken else {
#if DEBUG
                dlog(
                    "reactGrab.pasteback h3.copySuccess.drop " +
                    "workspace=\(workspaceId.uuidString.prefix(5)) " +
                    "browser=\(id.uuidString.prefix(5)) reason=tokenMismatch len=\(content.count)"
                )
#endif
                clearReactGrabRoundTrip(reason: "copySuccess.tokenMismatch")
                return
            }
#if DEBUG
            dlog(
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

    func injectReactGrab() async {
        #if DEBUG
        dlog("reactGrab.inject.start")
        #endif
        guard let scriptSource = await ReactGrabScriptLoader.fetch() else {
            #if DEBUG
            dlog("reactGrab.inject.fetchFailed")
            #endif
            return
        }
        #if DEBUG
        dlog("reactGrab.inject.fetched len=\(scriptSource.count)")
        #endif

        let handlerName = reactGrabMessageHandlerName
        let sessionTokenLiteral = reactGrabSessionTokenLiteral()
        let combined = """
        (function() {
            var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
            var updaterName = '\(reactGrabBridgeSessionUpdaterName)';
            var refreshSessionToken = function() {
                var syncToken = window[updaterName];
                if (typeof syncToken !== 'function') return false;
                return !!syncToken(\(sessionTokenLiteral));
            };
            var installBridge = function(api) {
                if (!api || window.__CMUX_REACT_GRAB_BRIDGE_INSTALLED__) return;
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
                    if (typeof window[updaterName] !== 'function') return;
                }
                refreshSessionToken();
                var lastActive;
                api.registerPlugin({
                    name: 'cmux-bridge',
                    hooks: {
                        onStateChange: function(state) {
                            if (state.isActive === lastActive) return;
                            lastActive = state.isActive;
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
            if (window.__REACT_GRAB__) {
                installBridge(window.__REACT_GRAB__);
                refreshSessionToken();
                window.__REACT_GRAB__.activate();
                return;
            }
            window.addEventListener('react-grab:init', function(e) {
                var api = e.detail;
                if (!api) return;
                installBridge(api);
                refreshSessionToken();
                api.activate();
            }, { once: true });
        })();
        \(scriptSource)
        """
        #if DEBUG
        dlog("reactGrab.inject.evalJS len=\(combined.count)")
        #endif
        webView.evaluateJavaScript(combined) { [weak self] _, error in
            #if DEBUG
            dlog("reactGrab.inject.evalJS.done error=\(error?.localizedDescription ?? "none")")
            #endif
            if let error {
                NSLog("ReactGrab: injection failed: %@", error.localizedDescription)
                Task { @MainActor in self?.isReactGrabActive = false }
            }
        }
        #if DEBUG
        dlog("reactGrab.inject.end")
        #endif
    }

    func toggleReactGrab() {
        #if DEBUG
        dlog("reactGrab.toggle.start")
        #endif
        let script = "window.__REACT_GRAB__?.toggle()"
        webView.evaluateJavaScript(script, completionHandler: nil)
        #if DEBUG
        dlog("reactGrab.toggle.end")
        #endif
    }

    func toggleOrInjectReactGrab() async {
        if isReactGrabActive {
            toggleReactGrab()
        } else {
            await injectReactGrab()
        }
    }

    func ensureReactGrabActive() async {
        if isReactGrabActive {
            guard pendingReactGrabRoundTripToken != nil else { return }
            if await refreshReactGrabBridgeSessionToken() {
                return
            }
        }
        await injectReactGrab()
    }

    @discardableResult
    func refreshReactGrabBridgeSessionToken() async -> Bool {
        do {
            let result = try await evaluateJavaScript(reactGrabBridgeSessionRefreshScript())
            return (result as? Bool) ?? false
        } catch {
#if DEBUG
            dlog("reactGrab.bridgeSessionRefresh.error error=\(error.localizedDescription)")
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
        dlog(
            "reactGrab.pasteback h3.reset " +
            "workspace=\(workspaceId.uuidString.prefix(5)) " +
            "browser=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) preserve=\(preserveRoundTrip ? 1 : 0) " +
            "pending=\(pendingTarget) active=\(isReactGrabActive ? 1 : 0)"
        )
#endif
        isReactGrabActive = false
        if !preserveRoundTrip {
            clearReactGrabRoundTrip(reason: reason)
        }
    }
}
