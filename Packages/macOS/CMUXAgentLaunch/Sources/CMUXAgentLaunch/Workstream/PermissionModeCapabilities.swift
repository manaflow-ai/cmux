public import Foundation

/// Which permission-approval modes a single `WorkstreamSource` offers for one
/// permission request. The booleans gate the per-mode approval affordances
/// (Allow Once / Always Allow / All tools) the UI and notification surfaces
/// render; the source-only `Bypass` affordance is decided directly on
/// `WorkstreamSource`.
///
/// The capabilities are derived from the agent (`WorkstreamSource`) and, for
/// Codex, the raw permission-request tool-input JSON, which carries the
/// approval method and the set of decisions Codex says it accepts. Non-Codex
/// agents support every persistent mode; Codex narrows the set per request.
public struct PermissionModeCapabilities: Sendable, Equatable {
    /// Whether the "Allow Once" mode is offered for this request.
    public let supportsOnce: Bool
    /// Whether the "Always Allow" (this-session) mode is offered for this request.
    public let supportsAlways: Bool
    /// Whether the "All tools" mode is offered for this request.
    public let supportsAll: Bool

    /// Creates a capability set with explicit per-mode availability.
    public init(supportsOnce: Bool, supportsAlways: Bool, supportsAll: Bool) {
        self.supportsOnce = supportsOnce
        self.supportsAlways = supportsAlways
        self.supportsAll = supportsAll
    }
}

extension WorkstreamSource {
    /// Whether this agent supports the persistent permission modes (Always /
    /// All). Hermes-agent does not persist approvals.
    public var supportsPersistentPermissionModes: Bool {
        self != .hermesAgent
    }

    /// Whether this agent supports the "Bypass" affordance (skip all future
    /// approvals). Codex, Claude, and Hermes-agent do not.
    public var supportsBypassPermissions: Bool {
        self != .codex && self != .claude && self != .hermesAgent
    }

    /// The per-mode permission capabilities for one permission request from this
    /// agent. `toolInputJSON` is the raw permission-request payload; it only
    /// affects Codex, where the accepted-decision set and approval method narrow
    /// which modes are offered. Non-Codex agents offer every mode their
    /// persistence support allows.
    public func permissionModeCapabilities(toolInputJSON: String?) -> PermissionModeCapabilities {
        let persistent = supportsPersistentPermissionModes
        guard self == .codex else {
            return PermissionModeCapabilities(
                supportsOnce: true,
                supportsAlways: persistent,
                supportsAll: persistent
            )
        }
        let codex = Self.codexCapabilities(toolInputJSON: toolInputJSON)
        return PermissionModeCapabilities(
            supportsOnce: codex.supportsOnce,
            supportsAlways: persistent && codex.supportsAlways,
            supportsAll: persistent && codex.supportsAll
        )
    }

    /// A normalized, sorted-key JSON snapshot of the Codex capability-relevant
    /// fields of a permission-request tool input, used as a stable cache /
    /// telemetry key. Returns `nil` for non-Codex sources or unparseable input.
    public func codexCapabilityToolInputJSON(toolInputJSON: String) -> String? {
        guard self == .codex else { return nil }
        return Self.codexCapabilityToolInputJSON(toolInputJSON: toolInputJSON)
    }

    private typealias CodexPermissionCapabilities = (supportsOnce: Bool, supportsAlways: Bool, supportsAll: Bool)

    private static func codexCapabilityToolInputJSON(toolInputJSON: String) -> String? {
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

    private static func codexCapabilities(toolInputJSON: String?) -> CodexPermissionCapabilities {
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
