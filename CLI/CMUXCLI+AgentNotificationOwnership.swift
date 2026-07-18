import Foundation

private let suppressSubagentNotificationsDefaultsKey = "suppressSubagentNotifications"
private let suppressSubagentNotificationsEnvironmentKey = "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS"
private let managedSubagentEnvironmentKey = "CMUX_AGENT_MANAGED_SUBAGENT"
#if DEBUG
private let testRootVisibleMutationsEnvironmentKey = "CMUX_TEST_AGENT_ROOT_VISIBLE_MUTATIONS"
#endif

extension CMUXCLI {
    func shouldSuppressNestedAgentVisibleMutations(
        currentAgentPID: Int?,
        agentName: String,
        nestedPromptEvent: Bool = false,
        transcriptSubagentSession: Bool = false,
        env: [String: String]
    ) -> Bool {
#if DEBUG
        if Self.parseHookBoolean(env[testRootVisibleMutationsEnvironmentKey] ?? "") == true {
            return false
        }
#endif
        if let override = normalizedHookValue(env["CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS"])?.lowercased(),
           Self.parseHookBoolean(override) == true {
            return true
        }
        if nestedPromptEvent || managedSubagentVisibleMutationSuppressionRequested(env: env) {
            return true
        }
        if transcriptSubagentSession {
            return true
        }
        guard let currentAgentPID, currentAgentPID > 1 else {
            return false
        }
        let kind = AgentVisibleMutationOwnershipAgentName().resolve(
            explicitAgentName: agentName,
            environment: env
        )
        return !AgentHookSessionLineageResolver().resolve(
            agentName: kind,
            sessionId: "unknown",
            pid: currentAgentPID,
            environment: env
        ).restoreAuthority
    }

    /// Child sessions never own the root surface's status, resume binding, or
    /// lifecycle. Notification delivery is a separate user policy: the default
    /// suppresses child alerts, while an explicit opt-in allows the alert only.
    func shouldSuppressNestedAgentNotification(
        visibleMutationsSuppressed: Bool,
        env: [String: String]
    ) -> Bool {
        visibleMutationsSuppressed && subagentNotificationSuppressionEnabled(env: env)
    }

    func subagentNotificationSuppressionEnabled(env: [String: String]) -> Bool {
        if let raw = normalizedHookValue(env[suppressSubagentNotificationsEnvironmentKey]),
           let parsed = Self.parseHookBoolean(raw) {
            return parsed
        }
        for defaults in appDefaultsCandidates(env: env) {
            if defaults.object(forKey: suppressSubagentNotificationsDefaultsKey) != nil {
                return defaults.bool(forKey: suppressSubagentNotificationsDefaultsKey)
            }
        }
        return true
    }

    private func appDefaultsCandidates(env: [String: String]) -> [UserDefaults] {
        var candidates: [UserDefaults] = []
        if let bundleId = normalizedHookValue(env["CMUX_BUNDLE_ID"]),
           let defaults = UserDefaults(suiteName: bundleId) {
            candidates.append(defaults)
        }
        candidates.append(.standard)
        return candidates
    }

    private func managedSubagentVisibleMutationSuppressionRequested(env: [String: String]) -> Bool {
        guard let raw = normalizedHookValue(env[managedSubagentEnvironmentKey]),
              let parsed = Self.parseHookBoolean(raw) else {
            return false
        }
        return parsed
    }

    static func parseHookBoolean(_ rawValue: String) -> Bool? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on", "enabled":
            return true
        case "0", "false", "no", "off", "disabled":
            return false
        default:
            return nil
        }
    }
}
