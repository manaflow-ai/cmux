import CryptoKit
import Foundation
import Network
import WebKit

/// Browser identity and networking stay separate: an HTTP CONNECT proxy never changes the document URL.
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public struct CloudBrowserRouting: Sendable {
    private static let probeQueue = DispatchQueue(label: "cmux.cloud.desktop-readiness")

    /// Test the service through the same authenticated carrier the page will use.
    /// A healthy desktop needs no control-plane exec. This short-lived stream is
    /// closed after the headers; no listener or persistent connection is added.
    public static func desktopIsReachable(
        endpoint: CloudBrowserProxyEndpoint,
        address: String,
        port: Int,
        timeout: Duration = .seconds(2),
        clock: any Clock<Duration> = ContinuousClock()
    ) async throws -> Bool {
        let host = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard endpoint.host == "127.0.0.1", endpoint.port != 0,
              (1...65535).contains(port), IPv4Address(host) != nil || IPv6Address(host) != nil else { return false }
        let authority = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        let credential = Data("\(endpoint.username):\(endpoint.password)".utf8).base64EncodedString()
        let connection = NWConnection(host: "127.0.0.1", port: .init(rawValue: endpoint.port)!, using: .tcp)
        defer { connection.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try await withDeadline(timeout, clock: clock) {
                    try await connection.startAndWaitUntilReady(queue: probeQueue)
                    try await connection.sendAll(Data("CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\nProxy-Authorization: Basic \(credential)\r\n\r\n".utf8))
                    guard try await responseStatus(connection) == 200 else { return false }
                    try await connection.sendAll(Data("HEAD /vnc.html HTTP/1.1\r\nHost: \(authority)\r\nConnection: close\r\n\r\n".utf8))
                    return try await responseStatus(connection) == 200
                }
            } onCancel: {
                connection.cancel()
            }
        } catch {
            try Task.checkCancellation()
            return false
        }
    }

    private static func withDeadline<T: Sendable>(
        _ duration: Duration,
        clock: any Clock<Duration>,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await clock.sleep(for: duration)
                throw CloudTunnelError.deadlineExceeded
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func responseStatus(_ connection: NWConnection) async throws -> Int? {
        var data = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while data.count < 8192 {
            let chunk = try await connection.receiveChunk(maximumLength: 8192 - data.count)
            if let bytes = chunk.data { data.append(bytes) }
            if let end = data.range(of: terminator) {
                let fields = String(decoding: data[..<end.lowerBound], as: UTF8.self)
                    .components(separatedBy: "\r\n")[0].split(separator: " ")
                guard fields.count >= 2, fields[0].hasPrefix("HTTP/1.") else { return nil }
                return Int(fields[1])
            }
            if chunk.isComplete { return nil }
        }
        return nil
    }

    public static func storeID(panelID: UUID, profileID: UUID, machineID: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("cloud-browser:\(panelID):\(profileID):\(machineID)".utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    public static func configuration(endpoint: CloudBrowserProxyEndpoint, address: String) -> ProxyConfiguration {
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .init(endpoint.host), port: .init(rawValue: endpoint.port)!))
        proxy.applyCredential(username: endpoint.username, password: endpoint.password)
        proxy.matchDomains = [address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))]
        proxy.allowFailover = false
        return proxy
    }

    /// Replace credentials as one script registration. An old document-start
    /// script must never win its installation guard after a carrier reconnect.
    @MainActor
    public static func installWebSocketBridge(endpoint: CloudBrowserProxyEndpoint, address: String, on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        let retained = controller.userScripts.filter { !$0.source.contains("window.__cmuxCloudWebSocketBridgeInstalled") }
        controller.removeAllUserScripts()
        for script in retained { controller.addUserScript(script) }
        if let source = websocketBridgeScript(endpoint: endpoint, address: address) {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
    }

    /// Installs the promptless WebSocket bridge used by WKWebView, whose page
    /// WebSocket implementation does not consistently honor `proxyConfigurations`.
    @MainActor
    static func websocketBridgeScript(endpoint: CloudBrowserProxyEndpoint, address: String) -> String? {
        guard let token = endpoint.websocketToken else { return nil }
        let host = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let encodedHost = host.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let encodedToken = token.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return """
        (() => {
          if (window.__cmuxCloudWebSocketBridgeInstalled) return;
          const targetHost = '\(encodedHost)'.toLowerCase();
          const token = '\(encodedToken)';
          const NativeWebSocket = window.WebSocket;
          if (typeof NativeWebSocket !== 'function') return;
          window.__cmuxCloudWebSocketBridgeInstalled = true;
          const rewrite = (input) => {
            let parsed;
            try { parsed = new URL(input, document.baseURI); } catch (_) { return null; }
            // Keep wss:// on WebKit's native CONNECT path. Rewriting it to ws://
            // would downgrade TLS and make the upstream handshake invalid.
            if (parsed.protocol !== 'ws:' || parsed.hostname.toLowerCase() !== targetHost) return null;
            const target = `${parsed.hostname}:${parsed.port || '80'}`;
            parsed.protocol = 'ws:';
            parsed.hostname = '127.0.0.1';
            parsed.port = String(\(endpoint.port));
            parsed.pathname = '/__cmux_ws__/' + target + parsed.pathname;
            return parsed.href;
          };
          window.__cmuxCloudWebSocketBridgeRewrite = rewrite;
          const originalURLs = new WeakMap();
          const CmuxWebSocket = class extends NativeWebSocket {
            constructor(input, protocols) {
            const rewritten = rewrite(input);
            if (!rewritten) { super(input, protocols); return; }
            const values = protocols === undefined ? [] : (typeof protocols === 'string' ? [protocols] : Array.from(protocols));
            const auth = 'cmux-proxy-' + token;
            if (!values.includes(auth)) values.push(auth);
            super(rewritten, values);
            originalURLs.set(this, new URL(input, document.baseURI).href);
            }
            get url() { return originalURLs.get(this) || super.url; }
          };
          window.__cmuxCloudWebSocketBridgeConstructor = CmuxWebSocket;
          window.WebSocket = CmuxWebSocket;
        })();
        """
    }

    /// Favicons use the page's authenticated browser route and cookies, rather than the OS network.
    @MainActor
    public static func favicon(url: URL, webView: WKWebView) async throws -> (Data, URLResponse) {
        let result = try await webView.callAsyncJavaScript("""
            const response = await fetch(url, {signal: AbortSignal.timeout(2000)});
            if (!response.ok || Number(response.headers.get('content-length')) > 2097152) throw new Error('Icon unavailable');
            const reader = response.body.getReader();
            let text = '', length = 0;
            while (true) {
              const {done, value} = await reader.read();
              if (done) break;
              length += value.length;
              if (length > 2097152) { await reader.cancel(); throw new Error('Icon too large'); }
              for (let i = 0; i < value.length; i += 8192) text += String.fromCharCode(...value.subarray(i, i + 8192));
            }
            return {data: btoa(text), status: response.status, type: response.headers.get('content-type') || ''};
            """, arguments: ["url": url.absoluteString], in: nil, contentWorld: .page)
        guard let value = result as? [String: Any], let encoded = value["data"] as? String,
              let data = Data(base64Encoded: encoded), let status = value["status"] as? Int,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                             headerFields: ["Content-Type": value["type"] as? String ?? ""]) else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }
}
