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

    private static func isAllowedPastebackScalar(_ scalar: Unicode.Scalar) -> Bool {
        if dangerousScalars.contains(scalar) {
            return false
        }

        switch scalar.value {
        case 0x09, 0x0A:
            return true
        case 0x00 ... 0x1F, 0x7F ... 0x9F:
            return false
        default:
            return true
        }
    }

    static func filtered(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter(isAllowedPastebackScalar)))
    }
}

enum ReactGrabPastebackContentExtractor {
    static let functionName = "__cmuxReactGrabExtractPastebackContent"

    static let installerSource = """
    (function() {
        var functionName = '\(functionName)';
        if (typeof window[functionName] === 'function') {
            return;
        }

        var blockTags = {
            ARTICLE: true, ASIDE: true, BLOCKQUOTE: true, BUTTON: true, DD: true,
            DETAILS: true, DIALOG: true, DIV: true, DL: true, DT: true,
            FIELDSET: true, FIGCAPTION: true, FIGURE: true, FOOTER: true,
            FORM: true, H1: true, H2: true, H3: true, H4: true, H5: true,
            H6: true, HEADER: true, HR: true, LI: true, MAIN: true, NAV: true,
            OL: true, P: true, PRE: true, SECTION: true, TABLE: true, TD: true,
            TH: true, UL: true
        };
        var skipTags = { NOSCRIPT: true, SCRIPT: true, STYLE: true, SVG: true, TEMPLATE: true };

        var normalizeWhitespace = function(text) {
            return String(text || '')
                .replace(/\\u00A0/g, ' ')
                .replace(/[ \\t\\f\\v\\r]+/g, ' ')
                .replace(/ *\\n+ */g, '\\n')
                .trim();
        };

        var normalizeBlockText = function(text) {
            return normalizeWhitespace(text).replace(/\\n{3,}/g, '\\n\\n').trim();
        };

        var normalizePreformattedText = function(text) {
            return String(text || '')
                .replace(/\\r\\n?/g, '\\n')
                .replace(/\\u00A0/g, ' ')
                .replace(/^\\n+|\\n+$/g, '');
        };

        var isHidden = function(element) {
            if (!element || element.nodeType !== Node.ELEMENT_NODE) return false;
            if (element.hasAttribute('hidden')) return true;
            if (element.getAttribute('aria-hidden') === 'true') return true;
            var style = window.getComputedStyle ? window.getComputedStyle(element) : null;
            return !!style && (style.display === 'none' || style.visibility === 'hidden');
        };

        var hasBlockChild = function(element) {
            for (var child = element.firstElementChild; child; child = child.nextElementSibling) {
                if (isHidden(child) || skipTags[child.tagName]) continue;
                if (blockTags[child.tagName] && child.tagName !== 'BUTTON') {
                    return true;
                }
            }
            return false;
        };

        var joinInlineParts = function(parts) {
            return normalizeWhitespace(parts.filter(Boolean).join(' '));
        };

        var textFromNode = function(node) {
            return normalizeWhitespace(node && node.textContent ? node.textContent : '');
        };

        var renderInline = function(node) {
            if (!node) return '';
            if (node.nodeType === Node.TEXT_NODE) {
                return normalizeWhitespace(node.textContent || '');
            }
            if (node.nodeType !== Node.ELEMENT_NODE) return '';

            var element = node;
            if (isHidden(element) || skipTags[element.tagName]) return '';

            if (element.tagName === 'BR') return '\\n';
            if (element.tagName === 'IMG') {
                return normalizeWhitespace(element.getAttribute('alt') || '');
            }
            if (element.tagName === 'INPUT') {
                var type = (element.getAttribute('type') || '').toLowerCase();
                if (type === 'button' || type === 'submit' || type === 'reset') {
                    return normalizeWhitespace(element.value || element.getAttribute('value') || '');
                }
            }
            if (element.tagName === 'A' && !hasBlockChild(element)) {
                var href = element.hasAttribute('href')
                    ? (element.getAttribute('href') || '')
                    : (element.href || '');
                var linkText = joinInlineParts(Array.prototype.map.call(element.childNodes, renderInline)) || textFromNode(element);
                if (!href) return linkText;
                return '[' + (linkText || href) + '](' + href + ')';
            }
            if (blockTags[element.tagName] && element.tagName !== 'BUTTON') {
                return textFromNode(element);
            }
            return joinInlineParts(Array.prototype.map.call(element.childNodes, renderInline));
        };

        var pushBlock = function(blocks, value) {
            var text = normalizeBlockText(value);
            if (!text) return;
            blocks.push(text);
        };

        var renderBlocks = function(node, blocks) {
            if (!node) return;
            if (node.nodeType === Node.TEXT_NODE) {
                pushBlock(blocks, node.textContent || '');
                return;
            }
            if (node.nodeType !== Node.ELEMENT_NODE) return;

            var element = node;
            if (isHidden(element) || skipTags[element.tagName]) return;

            if (element.tagName === 'PRE' || element.tagName === 'CODE') {
                var codeText = normalizePreformattedText(element.innerText || element.textContent || '');
                if (codeText) {
                    blocks.push('```\\n' + codeText + '\\n```');
                }
                return;
            }

            if (/^H[1-6]$/.test(element.tagName)) {
                var headingText = textFromNode(element);
                if (!headingText) return;
                if (element.tagName === 'H1' || element.tagName === 'H2') {
                    var underline = (element.tagName === 'H1' ? '=' : '-').repeat(Math.min(Math.max(headingText.length, 3), 80));
                    pushBlock(blocks, headingText + '\\n' + underline);
                } else {
                    var level = Number(element.tagName.slice(1)) || 3;
                    pushBlock(blocks, '#'.repeat(level) + ' ' + headingText);
                }
                return;
            }

            if (element.tagName === 'LI') {
                pushBlock(blocks, '- ' + textFromNode(element));
                return;
            }

            if (!hasBlockChild(element)) {
                if (element.tagName === 'BUTTON') {
                    var buttonText = joinInlineParts(Array.prototype.map.call(element.childNodes, renderInline)) ||
                        normalizeWhitespace(element.getAttribute('aria-label') || element.value || '');
                    pushBlock(blocks, buttonText);
                    return;
                }
                pushBlock(blocks, joinInlineParts(Array.prototype.map.call(element.childNodes, renderInline)) || textFromNode(element));
                return;
            }

            for (var child = element.firstChild; child; child = child.nextSibling) {
                renderBlocks(child, blocks);
            }
        };

        window[functionName] = function(elements, fallbackContent) {
            try {
                var roots = Array.isArray(elements) ? elements.filter(Boolean) : [];
                if (roots.length > 0) {
                    var blocks = [];
                    for (var i = 0; i < roots.length; i += 1) {
                        renderBlocks(roots[i], blocks);
                    }
                    var result = blocks.join('\\n\\n').replace(/\\n{3,}/g, '\\n\\n').trim();
                    if (result) return result;
                }
            } catch (_) {}
            return typeof fallbackContent === 'string' ? fallbackContent : String(fallbackContent || '');
        };
    })();
    """

    static func invocationScript(
        elementsExpression: String,
        fallbackContentLiteral: String
    ) -> String {
        """
        (function() {
            \(installerSource)
            return window['\(functionName)'](\(elementsExpression), \(fallbackContentLiteral));
        })();
        """
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
            \(ReactGrabPastebackContentExtractor.installerSource)
            var extractPastebackContent = window['\(ReactGrabPastebackContentExtractor.functionName)'];
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
                            var pastebackContent = content;
                            try {
                                if (typeof extractPastebackContent === 'function') {
                                    pastebackContent = extractPastebackContent(elements, content);
                                }
                            } catch (_) {}
                            if (handler) handler.postMessage({ type: 'copySuccess', content: String(pastebackContent || ''), token: token });
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
