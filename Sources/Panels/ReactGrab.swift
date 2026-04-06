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
    case copySuccess(content: String)

    init?(body: [String: Any]) {
        let type = body["type"] as? String ?? "stateChange"
        switch type {
        case "stateChange":
            guard let isActive = body["isActive"] as? Bool else { return nil }
            self = .stateChange(isActive: isActive)
        case "copySuccess":
            guard let content = body["content"] as? String else { return nil }
            self = .copySuccess(content: content)
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
        case .copySuccess(let content):
            dlog("reactGrab.messageHandler type=copySuccess len=\(content.count)")
        }
        #endif
        Task { @MainActor in
            #if DEBUG
            switch bridgeMessage {
            case .stateChange(let isActive):
                dlog("reactGrab.messageHandler.mainActor type=stateChange isActive=\(isActive)")
            case .copySuccess(let content):
                dlog("reactGrab.messageHandler.mainActor type=copySuccess len=\(content.count)")
            }
            #endif
            onMessage(bridgeMessage)
        }
    }
}

// MARK: - BrowserPanel extension

extension BrowserPanel {
    func setupReactGrabMessageHandler(for webView: WKWebView) {
        let handler = ReactGrabMessageHandler { [weak self] message in
            self?.handleReactGrabBridgeMessage(message)
        }
        reactGrabMessageHandler = handler
        webView.configuration.userContentController.add(handler, name: reactGrabMessageHandlerName)
    }

    func armReactGrabRoundTrip(returnTo panelId: UUID) {
#if DEBUG
        dlog(
            "reactGrab.pasteback h3.arm " +
            "workspace=\(workspaceId.uuidString.prefix(5)) " +
            "browser=\(id.uuidString.prefix(5)) " +
            "return=\(panelId.uuidString.prefix(5))"
        )
#endif
        pendingReactGrabReturnTargetPanelId = panelId
    }

    func clearReactGrabRoundTrip() {
        pendingReactGrabReturnTargetPanelId = nil
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
            if !isActive {
                clearReactGrabRoundTrip()
            }
        case .copySuccess(let content):
            guard let returnPanelId = pendingReactGrabReturnTargetPanelId else {
#if DEBUG
                dlog(
                    "reactGrab.pasteback h3.copySuccess.drop " +
                    "workspace=\(workspaceId.uuidString.prefix(5)) " +
                    "browser=\(id.uuidString.prefix(5)) reason=noReturnTarget len=\(content.count)"
                )
#endif
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
            clearReactGrabRoundTrip()
            NotificationCenter.default.post(
                name: .reactGrabDidCopySelection,
                object: nil,
                userInfo: [
                    ReactGrabPastebackNotificationKey.workspaceId: workspaceId,
                    ReactGrabPastebackNotificationKey.browserPanelId: id,
                    ReactGrabPastebackNotificationKey.returnPanelId: returnPanelId,
                    ReactGrabPastebackNotificationKey.content: content,
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
        let combined = """
        (function() {
            var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
            var installBridge = function(api) {
                if (!api || window.__CMUX_REACT_GRAB_BRIDGE_INSTALLED__) return;
                window.__CMUX_REACT_GRAB_BRIDGE_INSTALLED__ = true;
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
                            if (handler) handler.postMessage({ type: 'copySuccess', content: String(content || '') });
                        }
                    }
                });
            };
            if (window.__REACT_GRAB__) {
                installBridge(window.__REACT_GRAB__);
                window.__REACT_GRAB__.activate();
                return;
            }
            window.addEventListener('react-grab:init', function(e) {
                var api = e.detail;
                if (!api) return;
                installBridge(api);
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
        guard !isReactGrabActive else { return }
        await injectReactGrab()
    }

    func resetReactGrabState() {
        isReactGrabActive = false
        clearReactGrabRoundTrip()
    }
}
