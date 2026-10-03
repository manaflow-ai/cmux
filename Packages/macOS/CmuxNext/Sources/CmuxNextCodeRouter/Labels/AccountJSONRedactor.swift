import Foundation

/// Redacts a CodeRouter control-plane reply before it leaves the client.
/// Everywhere: every string has its emails shortened, and a key that holds
/// an email is replaced by its handle. On account endpoints, every account
/// row (an object with an `id` and a `provider` or `kind`) also gets an
/// `account` handle (a server `account` value moves to `server_account`), a redacted
/// `label`, and loses `providerAccountId` and `providerUserId`. Ids,
/// states and masked keys pass through unchanged.
struct AccountJSONRedactor {
    let labeler: AccountLabeler
    /// The reply lists or returns accounts (`/api/coderouter/accounts*`, `/api/coderouter/claude-upstream*`).
    let accountRows: Bool

    static func isAccountEndpoint(_ path: String) -> Bool {
        let path = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return ["/api/coderouter/accounts", "/api/coderouter/claude-upstream"].contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    func redact(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return Data(EmailRedaction.redactEmails(inBody: String(decoding: data, as: UTF8.self)).utf8)
        }
        return (try? JSONSerialization.data(withJSONObject: redact(value: object), options: [.fragmentsAllowed])) ?? Data("{}".utf8)
    }

    func redact(value: Any) -> Any {
        switch value {
        case let string as String: EmailRedaction.redactEmails(in: string)
        case let array as [Any]: array.map(redact(value:))
        case let object as [String: Any]: redact(object: object)
        default: value
        }
    }

    private func redact(object: [String: Any]) -> [String: Any] {
        var output: [String: Any] = [:]
        for (key, value) in object {
            let safeKey = EmailRedaction.containsEmail(key) ? labeler.handle(namespace: "json-key", identity: key) : key
            output[safeKey] = redact(value: value)
        }
        guard accountRows, let account = accountLabel(object) else { return output }
        // The handle always wins; a server `account` value (already redacted) moves aside.
        if let server = output["account"] { output["server_account"] = server }
        output["account"] = account.handle
        if let label = object["label"] as? String, !label.isEmpty { output["label"] = account.display }
        output["providerAccountId"] = nil
        output["providerUserId"] = nil
        return output
    }

    /// The same label ``LinkedAccount`` gets for this row.
    private func accountLabel(_ object: [String: Any]) -> AccountLabel? {
        guard let id = object["id"] as? String else { return nil }
        let namespace: String
        if let provider = object["provider"] as? String {
            namespace = AIProvider.fromCodeRouter(provider: provider)?.rawValue ?? provider
        } else if let kind = object["kind"] as? String {
            namespace = AIProvider.fromClaudeUpstream(kind: kind)?.rawValue ?? kind
        } else {
            return nil
        }
        return labeler.server(namespace: namespace, id: id, label: object["label"] as? String,
                              providerAccountId: object["providerAccountId"] as? String, identifier: object["identifier"] as? String)
    }
}
