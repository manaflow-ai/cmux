import CCmuxActionCatalogFFI
import Foundation

/// The links' logic lives in Rust (cmux-tui/crates/cmux-action-catalog, src/deep_link), linked
/// through CCmuxAppFFI: one JSON request in, one JSON value out, links in the shape the
/// synthesized `Codable` gives them.
nonisolated enum DeepLinkRust {
    /// One request (`op` and its fields, src/deep_link/json.rs); nil fields are left out.
    struct Request: Encodable {
        var op: String
        var url: String?
        var scheme: String?
        var link: DeepLink?
        var target: DeepLink.Target?
        var text: String?
        var rule: String?
        var prefix: String?
        var chief: Bool?
        var row: String?
        var schemes: [DeepLinkExport.Scheme]?
        var terminals: [DeepLink.AgentCandidate]?
        var harness: String?
        var session: String?
        var adopted: String?

        init(_ op: String, url: URL? = nil, scheme: String? = nil, link: DeepLink? = nil,
             target: DeepLink.Target? = nil, text: String? = nil, rule: String? = nil, prefix: String? = nil) {
            self.op = op
            self.url = url?.absoluteString
            self.scheme = scheme
            self.link = link
            self.target = target
            self.text = text
            self.rule = rule
            self.prefix = prefix
        }
    }

    /// Rust's answer to `request`, nil when it refused the request or the reply did not decode.
    static func call<Reply: Decodable>(_ request: Request, as type: Reply.Type) -> Reply? {
        guard let body = try? JSONEncoder().encode(request) else { return nil }
        var reply: UnsafeMutablePointer<UInt8>?
        var length = 0
        let status = body.withUnsafeBytes { bytes in
            cmux_deep_link_call(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &reply, &length)
        }
        guard status == 0, let reply else { return nil }
        defer { cmux_deep_link_free(reply, length) }
        return try? JSONDecoder().decode(type, from: Data(bytesNoCopy: reply, count: length, deallocator: .none))
    }

    /// An answer that may be JSON `null`.
    static func optional<Reply: Decodable>(_ request: Request, as type: Reply.Type) -> Reply? {
        call(request, as: Reply?.self) ?? nil
    }

    /// Whether `text` fits validator `rule` (`harness`, `resourceID` with a `prefix`, ...).
    static func valid(_ rule: String, _ text: String, prefix: String? = nil) -> Bool {
        call(Request("valid", text: text, rule: rule, prefix: prefix), as: Bool.self) ?? false
    }
}
