import Foundation
import CmuxCore

enum RemoteLoopbackRuntimeBridge {
    static let runtimeBridgeScriptSource: String = {
        let exactLoopbackHostLiterals = RemoteLoopbackProxyAlias.exactLoopbackHosts
            .sorted()
            .map(javaScriptStringLiteral)
            .joined(separator: ", ")
        return """
        (() => {
          const aliasHost = \(javaScriptStringLiteral(RemoteLoopbackProxyAlias.aliasHost));
          const canonicalLoopbackHost = \(javaScriptStringLiteral(RemoteLoopbackProxyAlias.canonicalLoopbackHost));
          const exactLoopbackHosts = new Set([\(exactLoopbackHostLiterals)]);
          const normalizeHost = (host) => {
            let value = String(host || '').trim().toLowerCase();
            if (!value) return '';
            if (value.endsWith('.')) value = value.slice(0, -1);
            if (value.startsWith('[') && value.endsWith(']')) {
              value = value.slice(1, -1);
            }
            return value;
          };
          const normalizedAliasHost = normalizeHost(aliasHost);
          const currentHost = normalizeHost(window.location.hostname);
          let effectiveHost = currentHost;
          if (!effectiveHost && window.location.protocol === 'about:') {
            try {
              effectiveHost = normalizeHost(new URL(document.baseURI).hostname);
            } catch (_) {}
          }
          if (effectiveHost !== normalizedAliasHost && !effectiveHost.endsWith(`.${normalizedAliasHost}`)) {
            return true;
          }
          if (window.__cmuxRemoteLoopbackRuntimeBridgeInstalled) return true;
          window.__cmuxRemoteLoopbackRuntimeBridgeInstalled = true;

          const loopbackAliasHost = (host) => {
            const normalizedHost = normalizeHost(host);
            if (exactLoopbackHosts.has(normalizedHost)) {
              return aliasHost;
            }
            const suffix = `.${canonicalLoopbackHost}`;
            if (normalizedHost.endsWith(suffix) && normalizedHost.length > suffix.length) {
              return `${normalizedHost.slice(0, -suffix.length)}.${aliasHost}`;
            }
            return null;
          };

          const rewriteLoopbackURL = (input) => {
            if (typeof input !== 'string' && !(input instanceof URL)) {
              return input;
            }
            const original = input instanceof URL ? input.href : input;
            let parsed;
            try {
              parsed = new URL(original, document.baseURI);
            } catch {
              return input;
            }
            // Only rewrite cleartext HTTP/WebSocket requests. TLS-bearing `https:` and
            // `wss:` validate certificates against the URL hostname, so aliasing them
            // would change SNI/certificate expectations for localhost dev servers.
            if (parsed.protocol !== 'http:' && parsed.protocol !== 'ws:') {
              return input;
            }
            const rewrittenHost = loopbackAliasHost(parsed.hostname);
            if (!rewrittenHost) {
              return input;
            }
            parsed.hostname = rewrittenHost;
            return parsed.href;
          };

          Object.defineProperty(window, '__cmuxRewriteRemoteLoopbackURL', {
            value: rewriteLoopbackURL,
            configurable: true,
          });

          const nativeFetch = window.fetch ? window.fetch.bind(window) : null;
          if (nativeFetch) {
            window.fetch = (input, init) => {
              if (typeof Request !== 'undefined' && input instanceof Request) {
                const rewrittenURL = rewriteLoopbackURL(input.url);
                if (rewrittenURL !== input.url) {
                  return nativeFetch(new Request(rewrittenURL, input), init);
                }
                return nativeFetch(input, init);
              }
              return nativeFetch(rewriteLoopbackURL(input), init);
            };
          }

          const nativeXHROpen = window.XMLHttpRequest && window.XMLHttpRequest.prototype.open;
          if (nativeXHROpen) {
            window.XMLHttpRequest.prototype.open = function(method, url, ...rest) {
              return nativeXHROpen.call(this, method, rewriteLoopbackURL(url), ...rest);
            };
          }

          const NativeWebSocket = window.WebSocket;
          if (typeof NativeWebSocket === 'function') {
            const CmuxWebSocket = function(url, protocols) {
              const rewrittenURL = rewriteLoopbackURL(url);
              if (protocols === undefined) {
                return new NativeWebSocket(rewrittenURL);
              }
              return new NativeWebSocket(rewrittenURL, protocols);
            };
            CmuxWebSocket.prototype = NativeWebSocket.prototype;
            Object.setPrototypeOf(CmuxWebSocket, NativeWebSocket);
            window.WebSocket = CmuxWebSocket;
          }

          const NativeEventSource = window.EventSource;
          if (typeof NativeEventSource === 'function') {
            const CmuxEventSource = function(url, eventSourceInitDict) {
              const rewrittenURL = rewriteLoopbackURL(url);
              if (eventSourceInitDict === undefined) {
                return new NativeEventSource(rewrittenURL);
              }
              return new NativeEventSource(rewrittenURL, eventSourceInitDict);
            };
            CmuxEventSource.prototype = NativeEventSource.prototype;
            Object.setPrototypeOf(CmuxEventSource, NativeEventSource);
            window.EventSource = CmuxEventSource;
          }

          return true;
        })();
        """
    }()

    private static func javaScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "'\(escaped)'"
    }
}
