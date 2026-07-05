import Foundation
public import CMUXAgentLaunch

/// Decides, per agent source and per-tool input, which permission-approval
/// buttons the Feed should offer (Allow Once / Always Allow / All tools /
/// Bypass). Codex advertises its available decisions inside the tool-input
/// JSON, so the Codex branches parse that payload to enable only the modes the
/// current request actually supports; every other source falls back to the
/// static per-source capability matrix.
///
/// This is a pure value policy shared by the Feed UI (`PermissionActionArea`),
/// the Feed coordinator, the notification-delivery seam, and the control-socket
/// feed context, so its decisions stay identical across every entrypoint.
public struct FeedPermissionActionPolicy: Sendable {
    private typealias CodexPermissionCapabilities = (supportsOnce: Bool, supportsAlways: Bool, supportsAll: Bool)

    /// Creates a stateless feed permission-action policy.
    public init() {}

    public func supportsPersistentPermissionModes(source: WorkstreamSource) -> Bool {
        source != .hermesAgent
    }

    public func supportsOncePermissionMode(source: WorkstreamSource, toolInputJSON: String?) -> Bool {
        guard source == .codex else { return true }
        return codexCapabilities(toolInputJSON: toolInputJSON).supportsOnce
    }

    public func supportsAlwaysPermissionMode(source: WorkstreamSource, toolInputJSON: String?) -> Bool {
        guard supportsPersistentPermissionModes(source: source) else { return false }
        guard source == .codex else { return true }
        return codexCapabilities(toolInputJSON: toolInputJSON).supportsAlways
    }

    public func supportsAllPermissionMode(source: WorkstreamSource, toolInputJSON: String?) -> Bool {
        guard supportsPersistentPermissionModes(source: source) else { return false }
        guard source == .codex else { return true }
        return codexCapabilities(toolInputJSON: toolInputJSON).supportsAll
    }

    public func supportsBypassPermissions(source: WorkstreamSource) -> Bool {
        source != .codex && source != .claude && source != .hermesAgent
    }

    public func codexCapabilityToolInputJSON(source: WorkstreamSource, toolInputJSON: String) -> String? {
        guard source == .codex else { return nil }
        return codexCapabilityToolInputJSON(toolInputJSON: toolInputJSON)
    }

    private func codexCapabilityToolInputJSON(toolInputJSON: String) -> String? {
        guard let data = toolInputJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }

        var snapshot: [String: Any] = [:]
        if let method = object["app_server_method"] as? String {
            snapshot["app_server_method"] = method
        }
        if let decisions = codexAvailableDecisions(in: object) {
            snapshot["available_decisions"] = decisions.sorted()
        }
        if let amendment = object["proposed_execpolicy_amendment"],
           !(amendment is NSNull) {
            snapshot["proposed_execpolicy_amendment"] = true
        }
        if let amendments = object["proposed_network_policy_amendments"] as? [Any],
           !amendments.isEmpty {
            snapshot["proposed_network_policy_amendments"] = [true]
        }

        guard let snapshotData = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: snapshotData, encoding: .utf8)
    }

    private func codexCapabilities(toolInputJSON: String?) -> CodexPermissionCapabilities {
        guard let toolInputJSON else {
            return (supportsOnce: true, supportsAlways: true, supportsAll: true)
        }
        guard let data = toolInputJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return (supportsOnce: false, supportsAlways: false, supportsAll: false)
        }

        let method = object["app_server_method"] as? String
        let decisions = codexAvailableDecisions(in: object)
        let acceptsOnce = decisions?.contains("accept") ?? true
        let acceptsSession = decisions?.contains("acceptForSession") ?? true
        switch method {
        case "item/permissions/requestApproval":
            return (
                supportsOnce: true,
                supportsAlways: true,
                supportsAll: true
            )
        case "item/commandExecution/requestApproval":
            return (
                supportsOnce: acceptsOnce,
                supportsAlways: acceptsSession,
                supportsAll: codexSupportsAmendmentDecision(object: object, decisions: decisions)
            )
        case "item/fileChange/requestApproval":
            return (
                supportsOnce: acceptsOnce,
                supportsAlways: acceptsSession,
                supportsAll: false
            )
        default:
            return (
                supportsOnce: acceptsOnce,
                supportsAlways: acceptsSession,
                supportsAll: false
            )
        }
    }

    private func codexSupportsAmendmentDecision(object: [String: Any], decisions: Set<String>?) -> Bool {
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

    private func codexAvailableDecisions(in object: [String: Any]) -> Set<String>? {
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

    private func codexDecisionAvailableOrUnspecified(_ decision: String, decisions: Set<String>?) -> Bool {
        decisions?.contains(decision) ?? true
    }
}
