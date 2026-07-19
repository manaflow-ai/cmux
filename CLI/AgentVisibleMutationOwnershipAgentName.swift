import Foundation

/// Resolves the agent kind that owns user-visible session mutations.
struct AgentVisibleMutationOwnershipAgentName: Sendable {
    func resolve(
        explicitAgentName: String?,
        environment: [String: String]
    ) -> String {
        normalized(explicitAgentName)
            ?? normalized(environment["CMUX_AGENT_LAUNCH_KIND"])
            ?? "agent"
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
