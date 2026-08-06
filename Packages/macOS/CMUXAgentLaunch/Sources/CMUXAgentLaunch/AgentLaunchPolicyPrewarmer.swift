/// Materializes agent launch-policy metadata before a resource-pressure path needs it.
public struct AgentLaunchPolicyPrewarmer: Sendable {
    private let loadPolicyCount: @Sendable () -> Int

    /// Creates a prewarmer for cmux's registered agent launch policies.
    public init() {
        loadPolicyCount = {
            let policies = [
                AgentLaunchSanitizer.claudePolicy,
                AgentLaunchSanitizer.codexPolicy,
                AgentLaunchSanitizer.piPolicy,
                AgentLaunchSanitizer.ampPolicy,
                AgentLaunchSanitizer.geminiPolicy,
                AgentLaunchSanitizer.antigravityPolicy,
                AgentLaunchSanitizer.cursorPolicy,
                AgentLaunchSanitizer.openCodePolicy,
                AgentLaunchSanitizer.grokPolicy,
                AgentLaunchSanitizer.kimiPolicy,
                AgentLaunchSanitizer.copilotPolicy,
                AgentLaunchSanitizer.codeBuddyPolicy,
                AgentLaunchSanitizer.factoryPolicy,
                AgentLaunchSanitizer.qoderPolicy,
                AgentLaunchSanitizer.kiroPolicy,
                AgentLaunchSanitizer.rovoDevPolicy,
                AgentLaunchSanitizer.hermesAgentPolicy,
            ]
            return policies.count
        }
    }

    /// Loads immutable policy metadata on the caller's executor.
    ///
    /// - Returns: The number of registered launch policies that were loaded.
    @discardableResult
    public func prewarmPolicies() -> Int {
        loadPolicyCount()
    }
}
