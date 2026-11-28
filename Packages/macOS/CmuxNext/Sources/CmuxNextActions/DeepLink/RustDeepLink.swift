import CCmuxActionCatalogFFI
import Foundation

/// The link logic in Rust (cmux-action-catalog `deep_link`, `cmux_deep_link_call`): one JSON
/// request in (`{"op": …}`), one JSON value out. Links cross in the shape `DeepLink`'s synthesized
/// `Codable` gives them. Every parse, format and id rule lives there; Swift keeps the types and the
/// app's plans.
nonisolated enum RustDeepLink {
    /// The reply to `request`, or nil when Rust refused it (the request is a bug here, not input).
    static func call(_ request: [String: Any]) -> Any? {
        guard let body = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        var reply: UnsafeMutablePointer<UInt8>?
        var length = 0
        let status = body.withUnsafeBytes { bytes in
            cmux_deep_link_call(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &reply, &length)
        }
        guard status == 0, let reply else { return nil }
        defer { cmux_deep_link_free(reply, length) }
        let data = Data(bytes: reply, count: length)
        return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    static func text(_ request: [String: Any]) -> String? {
        call(request) as? String
    }

    static func bool(_ request: [String: Any]) -> Bool {
        call(request) as? Bool ?? false
    }

    static func link(_ request: [String: Any]) -> DeepLink? {
        call(request).flatMap(decode)
    }

    static func decode(_ value: Any) -> DeepLink? {
        guard value is [String: Any], let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(DeepLink.self, from: data)
    }

    static func encode(_ value: some Encodable) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return NSNull() }
        return object
    }

    static func valid(_ rule: String, _ text: String, prefix: String? = nil) -> Bool {
        var request: [String: Any] = ["op": "valid", "rule": rule, "text": text]
        if let prefix { request["prefix"] = prefix }
        return bool(request)
    }
}
