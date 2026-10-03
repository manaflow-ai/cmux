import Foundation

/// Redacts a CodeRouter control-plane reply before it leaves the client:
/// every account row (an object with an `id` and a `provider` or `kind`)
/// gets `account` (its handle) and a `label` with every email shortened,
/// and every other string anywhere in the reply has its emails shortened.
/// Ids, states and masked keys pass through unchanged.
struct AccountJSONRedactor {
    let labeler: AccountLabeler

    func redact(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return Data(EmailRedaction.redactEmails(in: String(decoding: data, as: UTF8.self)).utf8)
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
        for (key, value) in object { output[EmailRedaction.redactEmails(in: key)] = redact(value: value) }
        if let account = accountLabel(object) {
            output["account"] = account.handle
            if let label = object["label"] as? String, !label.isEmpty { output["label"] = account.display }
        }
        return output
    }

    /// The same handle ``LinkedAccount`` gets: provider id + the first
    /// non-empty of label, providerAccountId, identifier.
    private func accountLabel(_ object: [String: Any]) -> AccountLabel? {
        guard object["id"] is String else { return nil }
        let namespace: String
        if let provider = object["provider"] as? String {
            namespace = AIProvider.fromCodeRouter(provider: provider)?.rawValue ?? provider
        } else if let kind = object["kind"] as? String {
            namespace = AIProvider.fromClaudeUpstream(kind: kind)?.rawValue ?? kind
        } else {
            return nil
        }
        let label = ["label", "providerAccountId", "identifier"].lazy.compactMap { object[$0] as? String }.first { !$0.isEmpty }
        return label.map { labeler.server(namespace: namespace, label: $0) }
    }
}
