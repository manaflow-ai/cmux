import Foundation

enum RemoteLoopbackProxyAlias {
    static let aliasHost = "cmux-loopback.localtest.me"

    private static let canonicalLoopbackHost = "localhost"
    private static let exactLoopbackHosts: Set<String> = [
        canonicalLoopbackHost,
        "127.0.0.1",
        "::1",
        "0.0.0.0",
    ]

    static func isLoopbackHost(_ host: String) -> Bool {
        guard let normalizedHost = BrowserInsecureHTTPSettings.normalizeHost(host) else {
            return false
        }
        return exactLoopbackHosts.contains(normalizedHost)
            || normalizedHost.hasSuffix(".\(canonicalLoopbackHost)")
    }

    static func browserAliasHost(forLoopbackHost host: String, aliasHost: String) -> String {
        localhostFamilyAliasHost(forLoopbackHost: host, aliasHost: aliasHost) ?? aliasHost
    }

    static func localhostFamilyHost(forAliasHost host: String, aliasHost: String) -> String? {
        guard let normalizedHost = BrowserInsecureHTTPSettings.normalizeHost(host),
              let normalizedAlias = BrowserInsecureHTTPSettings.normalizeHost(aliasHost) else {
            return nil
        }
        if normalizedHost == normalizedAlias {
            return canonicalLoopbackHost
        }

        let suffix = ".\(normalizedAlias)"
        guard normalizedHost.hasSuffix(suffix) else { return nil }
        let prefix = String(normalizedHost.dropLast(suffix.count))
        guard !prefix.isEmpty else { return nil }
        return "\(prefix).\(canonicalLoopbackHost)"
    }

    static func localhostFamilyAliasHost(forLoopbackHost host: String, aliasHost: String) -> String? {
        guard let normalizedHost = BrowserInsecureHTTPSettings.normalizeHost(host) else { return nil }
        if normalizedHost == canonicalLoopbackHost {
            return aliasHost
        }

        let suffix = ".\(canonicalLoopbackHost)"
        guard normalizedHost.hasSuffix(suffix) else { return nil }
        let prefix = String(normalizedHost.dropLast(suffix.count))
        guard !prefix.isEmpty else { return nil }
        return "\(prefix).\(aliasHost)"
    }

    static let runtimeBridgeScriptSource: String = {
        let exactLoopbackHostLiterals = exactLoopbackHosts
            .sorted()
            .map(javaScriptStringLiteral)
            .joined(separator: ", ")
        """
        (() => {
          const aliasHost = \(javaScriptStringLiteral(aliasHost));
          const canonicalLoopbackHost = \(javaScriptStringLiteral(canonicalLoopbackHost));
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
            // Keep HMR/streaming WebSocket upgrades (`ws:`/`wss:`) on the SSH proxy alias,
            // while leaving `https:` alone to avoid changing certificate expectations.
            if (parsed.protocol !== 'http:' && parsed.protocol !== 'ws:' && parsed.protocol !== 'wss:') {
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
