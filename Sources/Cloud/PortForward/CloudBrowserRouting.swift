import CryptoKit
import Foundation
import Network
import WebKit

/// Browser identity and networking stay separate: a SOCKS5 proxy never changes the document URL.
struct CloudBrowserRouting {
    static func storeID(panelID: UUID, profileID: UUID, machineID: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("cloud-browser:\(panelID):\(profileID):\(machineID)".utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func configuration(endpoint: CloudBrowserProxyEndpoint, address: String) -> ProxyConfiguration {
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: .init(endpoint.host), port: .init(rawValue: endpoint.port)!))
        proxy.applyCredential(username: endpoint.username, password: endpoint.password)
        proxy.matchDomains = [address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))]
        proxy.allowFailover = false
        return proxy
    }

    /// Favicons use the page's authenticated browser route and cookies, rather than the OS network.
    @MainActor
    static func favicon(url: URL, webView: WKWebView) async throws -> (Data, URLResponse) {
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
