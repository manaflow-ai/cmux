public import Foundation

/// JavaScript sources for the React Grab native bridge.
///
/// Two content worlds split the authority:
///
/// - The **relay** and the **token sync** run in the React Grab isolated
///   content world (`WKContentWorld.world(name:)`), together with the native
///   script message handler. Page JavaScript cannot see that world's globals,
///   its `window.webkit.messageHandlers`, or the round-trip token.
/// - The **page bridge** runs in the page world next to the react-grab
///   library (component inspection needs page-world React internals). It has
///   no native handler access and no token; it only mirrors library events to
///   the relay via `window.postMessage`, whose payloads cross content worlds
///   as structured clones.
///
/// The templates are kept free of Swift interpolation so the
/// `tests/react_grab_bridge.test.mjs` harness can extract and execute the
/// exact shipped sources between the begin/end markers.
public struct ReactGrabBridgeScripts {
    private init() {}
    public static let handlerNamePlaceholder = "__CMUX_RG_HANDLER__"
    public static let maxContentLengthPlaceholder = "__CMUX_RG_MAX_CONTENT_LENGTH__"
    public static let tokenLiteralPlaceholder = "__CMUX_RG_TOKEN_LITERAL__"

    /// Maximum relayed copy content length in UTF-16 units, enforced by the
    /// relay before anything reaches the native handler. The native gate
    /// backstops this bound in UTF-8 bytes
    /// (``ReactGrabPastebackGate/maxContentUTF8Bytes``).
    public static let maxContentLength = 131_072

    /// Isolated-world relay: owns the one-shot round-trip token and the only
    /// code path allowed to post to the native handler. Accepts only
    /// same-window messages, so another frame cannot address it.
    static let relayTemplate = #"""
    // cmux-react-grab-relay-begin
    (function () {
        'use strict';
        if (window.__cmuxReactGrabRelay) { return true; }
        var armedToken = null;
        var relay = {
            sync: function (token) {
                armedToken = (typeof token === 'string' && token.length > 0) ? token : null;
                return true;
            }
        };
        try {
            Object.defineProperty(window, '__cmuxReactGrabRelay', {
                value: relay,
                writable: false,
                configurable: false,
                enumerable: false
            });
        } catch (error) {
            return false;
        }
        window.addEventListener('message', function (event) {
            if (event.source !== window) { return; }
            var data = event.data;
            if (!data || data.__cmuxReactGrab !== true || typeof data.type !== 'string') { return; }
            var messageHandlers = window.webkit && window.webkit.messageHandlers;
            var handler = messageHandlers && messageHandlers['__CMUX_RG_HANDLER__'];
            if (!handler) { return; }
            if (data.type === 'stateChange') {
                handler.postMessage({ type: 'stateChange', isActive: !!data.isActive });
                return;
            }
            if (data.type !== 'copySuccess') { return; }
            var token = armedToken;
            armedToken = null;
            if (token === null) { return; }
            if (typeof data.content !== 'string') { return; }
            if (data.content.length > __CMUX_RG_MAX_CONTENT_LENGTH__) { return; }
            handler.postMessage({ type: 'copySuccess', content: data.content, token: token });
        });
        return true;
    })();
    // cmux-react-grab-relay-end
    """#

    /// Isolated-world token sync: arms (or, with `null`, disarms) the relay.
    static let tokenSyncTemplate = #"""
    // cmux-react-grab-token-sync-begin
    (function () {
        'use strict';
        var relay = window.__cmuxReactGrabRelay;
        if (!relay || typeof relay.sync !== 'function') { return false; }
        return relay.sync(__CMUX_RG_TOKEN_LITERAL__) === true;
    })();
    // cmux-react-grab-token-sync-end
    """#

    /// Page-world bridge: mirrors react-grab plugin events to the relay. It
    /// must never reference the native handler or carry round-trip secrets.
    static let pageBridgeTemplate = #"""
    // cmux-react-grab-page-bridge-begin
    (function () {
        'use strict';
        var post = function (payload) {
            payload.__cmuxReactGrab = true;
            window.postMessage(payload, '*');
        };
        var installBridge = function (api) {
            if (!api || window.__CMUX_REACT_GRAB_BRIDGE_INSTALLED__) { return; }
            window.__CMUX_REACT_GRAB_BRIDGE_INSTALLED__ = true;
            var lastActive;
            api.registerPlugin({
                name: 'cmux-bridge',
                hooks: {
                    onStateChange: function (state) {
                        if (state.isActive === lastActive) { return; }
                        lastActive = state.isActive;
                        post({ type: 'stateChange', isActive: !!state.isActive });
                    },
                    onCopySuccess: function (elements, content) {
                        post({ type: 'copySuccess', content: String(content || '') });
                    }
                }
            });
        };
        if (window.__REACT_GRAB__) {
            installBridge(window.__REACT_GRAB__);
            window.__REACT_GRAB__.activate();
            return;
        }
        window.addEventListener('react-grab:init', function (event) {
            var api = event.detail;
            if (!api) { return; }
            installBridge(api);
            api.activate();
        }, { once: true });
    })();
    // cmux-react-grab-page-bridge-end
    """#

    public static func relaySource(handlerName: String) -> String {
        relayTemplate
            .replacingOccurrences(of: handlerNamePlaceholder, with: handlerName)
            .replacingOccurrences(of: maxContentLengthPlaceholder, with: String(maxContentLength))
    }

    public static func tokenSyncSource(token: String?) -> String {
        tokenSyncTemplate.replacingOccurrences(
            of: tokenLiteralPlaceholder,
            with: javaScriptStringLiteral(for: token)
        )
    }

    public static func pageBridgeSource() -> String {
        pageBridgeTemplate
    }

    /// Renders an optional token as a single-quoted JavaScript literal.
    /// Tokens are native-minted UUID strings; the escaping is defensive.
    private static func javaScriptStringLiteral(for token: String?) -> String {
        guard let token else { return "null" }
        var escaped = ""
        escaped.reserveCapacity(token.count + 2)
        for scalar in token.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "'": escaped += "\\'"
            case "\n", "\r", "\u{2028}", "\u{2029}": continue
            default:
                if scalar.value < 0x20 { continue }
                escaped.unicodeScalars.append(scalar)
            }
        }
        return "'\(escaped)'"
    }
}
