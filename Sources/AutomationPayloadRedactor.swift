import Foundation

/// Removes credential-like values before automation data crosses an API
/// boundary or is rendered by the CLI.
nonisolated struct AutomationPayloadRedactor: Sendable {
    private let sensitiveKeyFragments = [
        "authorization", "token", "secret", "password", "apikey", "credential", "cookie", "privatekey", "headers", "session"
    ]

    /// Creates a stateless redactor with the product's sensitive-key policy.
    init() {}

    /// Returns a rule copy whose predicates and action parameters are safe to display.
    func rule(_ rule: AutomationRule) -> AutomationRule {
        AutomationRule(
            id: rule.id,
            when: rule.when,
            predicates: rule.predicates.reduce(into: [String: AutomationJSONValue]()) { result, entry in
                result[entry.key] = self.value(entry.value, key: entry.key)
            },
            actions: rule.actions.map { action in
                var parameters: [String: AutomationJSONValue] = [:]
                for (key, value) in action.parameters {
                    parameters[key] = self.value(value, key: key)
                }
                return AutomationAction(action: action.action, parameters: parameters)
            },
            enabled: rule.enabled,
            rateLimit: rule.rateLimit
        )
    }

    /// Returns an action payload whose credential-like fields are redacted.
    func actionPayload(_ action: AutomationAction) -> [String: Any] {
        var payload: [String: Any] = ["action": action.action]
        for (key, item) in action.parameters {
            payload[key] = value(item, key: key).foundationObject
        }
        return payload
    }

    /// Returns an event payload whose credential-like fields are redacted.
    func event(_ event: [String: Any]) -> [String: Any] {
        redactedFoundationObject(event, key: nil) as? [String: Any] ?? [:]
    }

    private func value(_ item: AutomationJSONValue, key: String?) -> AutomationJSONValue {
        guard !isSensitiveKey(key) else { return .string("[redacted]") }
        switch item {
        case .array(let items):
            return .array(items.map { value($0, key: key) })
        case .object(let object):
            var redacted: [String: AutomationJSONValue] = [:]
            for (childKey, childValue) in object {
                redacted[childKey] = value(childValue, key: childKey)
            }
            return .object(redacted)
        case .string(let string):
            return .string(redactedURL(string, key: key))
        default:
            return item
        }
    }

    private func redactedFoundationObject(_ item: Any, key: String?) -> Any {
        guard !isSensitiveKey(key) else { return "[redacted]" }
        switch item {
        case let object as [String: Any]:
            var redacted: [String: Any] = [:]
            for (childKey, childValue) in object {
                redacted[childKey] = redactedFoundationObject(childValue, key: childKey)
            }
            return redacted
        case let array as [Any]:
            return array.map { redactedFoundationObject($0, key: key) }
        case let string as String:
            return redactedURL(string, key: key)
        default:
            return item
        }
    }

    /// Removes userinfo and credential-like query values from URL fields.
    private func redactedURL(_ raw: String, key: String?) -> String {
        guard isURLKey(key), var components = URLComponents(string: raw) else {
            return raw
        }
        var changed = false
        if components.user != nil {
            components.user = "[redacted]"
            changed = true
        }
        if components.password != nil {
            components.password = "[redacted]"
            changed = true
        }
        if let queryItems = components.queryItems {
            components.queryItems = queryItems.map { item in
                guard isSensitiveURLQueryKey(item.name) else { return item }
                changed = true
                return URLQueryItem(name: item.name, value: "[redacted]")
            }
        }
        return changed ? (components.string ?? raw) : raw
    }

    private func isURLKey(_ key: String?) -> Bool {
        guard let key else { return false }
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return normalized.contains("url") || normalized.contains("endpoint")
    }

    private func isSensitiveKey(_ key: String?) -> Bool {
        guard let key else { return false }
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return sensitiveKeyFragments.contains { normalized.contains($0) }
    }

    private func isSensitiveURLQueryKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return isSensitiveKey(key)
            || normalized == "key"
            || normalized == "auth"
            || normalized == "authcode"
            || normalized == "authentication"
            || normalized == "oauth"
            || normalized == "sig"
            || normalized.hasSuffix("signature")
    }
}
