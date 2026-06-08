import Foundation
import CMUXWorkstream

enum FeedPermissionActionPolicy {
    static func supportsPersistentPermissionModes(source: WorkstreamSource) -> Bool {
        source != .hermesAgent
    }

    static func supportsOncePermissionMode(source: WorkstreamSource, toolInputJSON: String?) -> Bool {
        guard source == .codex else { return true }
        return codexCapabilities(toolInputJSON: toolInputJSON).supportsOnce
    }

    static func supportsAlwaysPermissionMode(source: WorkstreamSource, toolInputJSON: String?) -> Bool {
        guard supportsPersistentPermissionModes(source: source) else { return false }
        guard source == .codex else { return true }
        return codexCapabilities(toolInputJSON: toolInputJSON).supportsAlways
    }

    static func supportsAllPermissionMode(source: WorkstreamSource, toolInputJSON: String?) -> Bool {
        guard supportsPersistentPermissionModes(source: source) else { return false }
        guard source == .codex else { return true }
        return codexCapabilities(toolInputJSON: toolInputJSON).supportsAll
    }

    static func supportsBypassPermissions(source: WorkstreamSource) -> Bool {
        source != .codex && source != .claude && source != .hermesAgent
    }

    private static func codexCapabilities(toolInputJSON: String?) -> CodexPermissionCapabilities {
        guard let toolInputJSON,
              let data = toolInputJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return CodexPermissionCapabilities(supportsOnce: true, supportsAlways: true, supportsAll: true)
        }

        let method = object["app_server_method"] as? String
        let decisions = codexAvailableDecisions(in: object)
        let acceptsOnce = decisions?.contains("accept") ?? true
        let acceptsSession = decisions?.contains("acceptForSession") ?? true
        switch method {
        case "item/permissions/requestApproval":
            return CodexPermissionCapabilities(
                supportsOnce: true,
                supportsAlways: true,
                supportsAll: true
            )
        case "item/commandExecution/requestApproval":
            return CodexPermissionCapabilities(
                supportsOnce: acceptsOnce,
                supportsAlways: acceptsSession,
                supportsAll: codexSupportsAmendmentDecision(object: object, decisions: decisions)
            )
        case "item/fileChange/requestApproval":
            return CodexPermissionCapabilities(
                supportsOnce: acceptsOnce,
                supportsAlways: decisions?.contains("acceptForSession") ?? false,
                supportsAll: false
            )
        default:
            return CodexPermissionCapabilities(
                supportsOnce: acceptsOnce,
                supportsAlways: acceptsSession,
                supportsAll: false
            )
        }
    }

    private static func codexSupportsAmendmentDecision(object: [String: Any], decisions: Set<String>?) -> Bool {
        if let amendment = object["proposed_execpolicy_amendment"],
           codexDecisionAvailableOrUnspecified("acceptWithExecpolicyAmendment", decisions: decisions),
           !(amendment is NSNull) {
            return true
        }
        if let amendments = object["proposed_network_policy_amendments"] as? [Any],
           !amendments.isEmpty,
           codexDecisionAvailableOrUnspecified("applyNetworkPolicyAmendment", decisions: decisions) {
            return true
        }
        return false
    }

    private static func codexAvailableDecisions(in object: [String: Any]) -> Set<String>? {
        guard let raw = object["available_decisions"] ?? object["availableDecisions"] else {
            return nil
        }
        let values = raw as? [Any] ?? []
        return Set(values.compactMap { value in
            if let string = value as? String {
                return string
            }
            if let object = value as? [String: Any],
               let key = object.keys.first {
                return key
            }
            return nil
        })
    }

    private static func codexDecisionAvailableOrUnspecified(_ decision: String, decisions: Set<String>?) -> Bool {
        decisions?.contains(decision) ?? true
    }
}

private struct CodexPermissionCapabilities {
    let supportsOnce: Bool
    let supportsAlways: Bool
    let supportsAll: Bool
}
