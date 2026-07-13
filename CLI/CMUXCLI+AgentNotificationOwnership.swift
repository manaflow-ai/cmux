import Foundation

private let suppressSubagentNotificationsDefaultsKey = "suppressSubagentNotifications"
private let suppressSubagentNotificationsEnvironmentKey = "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS"

extension CMUXCLI {
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
}
