import CmuxNextBrowser
import Foundation
import WebKit

extension WebKitDriver {
    /// Resolve first, then probe that same frame in the host's untampered content world. Include
    /// the native security origin as well: frame metadata can predate a cross-origin navigation.
    func frameCodeOrigins(_ frame: WKFrameInfo?, tab: WebKitTab) async throws(DriverError) -> (origin: String, all: [String]) {
        let value = try await run("return this.location.origin;", [:], frame, AgentWorld.hostWorld, tab)
        guard case .string(let origin) = value, !origin.isEmpty else {
            throw DriverError(.invalid, "frame.evaluate: the frame has no verifiable web origin")
        }
        // An opaque/inherited frame can change documents without changing location.origin.
        // `null` asks the host to reserve the whole profile against fills, while still allowing
        // normal scripting of blank tabs when that profile has never held a filled sign-in.
        let isWeb = Self.frameWebOrigin(origin) == origin
        var origins = isWeb ? [origin] : ["null"]
        if !origins.contains(origin) { origins.append(origin) }
        let native: String?
        if let frame {
            let site = frame.securityOrigin
            var url = URLComponents()
            url.scheme = site.protocol
            url.host = site.host
            if site.port > 0 { url.port = site.port }
            native = url.url.flatMap { Self.frameWebOrigin($0.absoluteString) }
        } else {
            native = tab.webView.url.flatMap { Self.frameWebOrigin($0.absoluteString) }
        }
        if let native, !origins.contains(native) { origins.append(native) }
        return (origin, origins)
    }

    private static func frameWebOrigin(_ raw: String) -> String? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        if let port = url.port, port != (scheme == "https" ? 443 : 80) { origin.port = port }
        return origin.string
    }

    /// Each WebKit stage checks in the same JS call that executes its code. Bodies containing
    /// agent source are parsed as complete async function bodies before WebKit sees them, so
    /// source cannot escape its generated function. `this` is WebKit's WindowProxy receiver,
    /// unaffected by declarations or globals named location/globalThis in agent source. Throw
    /// a literal: source may hoist a declaration named Error before this guard executes.
    static func pinFrameCode(_ body: String, origin: String?) throws(DriverError) -> String {
        guard let origin else { return body }
        guard let data = try? JSONEncoder().encode(origin), let encoded = String(data: data, encoding: .utf8) else {
            throw DriverError(.invalid, "frame.evaluate: invalid origin")
        }
        return "if (this.location.origin !== \(encoded)) throw 'frame.evaluate: the frame navigated';\n" + body
    }
}
