import Foundation

/// The agent last picked on the new tab screen, kept on this Mac across
/// relaunches (decision Q3: app-local memory; one input without a mode,
/// R86). Client view state, so it never reaches the daemon.
@MainActor
final class NewTabChoiceMemory {
    private static let agentKey = "newTab.lastAgent"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var agent: String? { defaults.string(forKey: Self.agentKey).flatMap { $0.isEmpty ? nil : $0 } }

    /// A value the page should never send (empty, too long) is ignored.
    func remember(agent: String) {
        guard !agent.isEmpty, agent.count <= 128 else { return }
        defaults.set(agent, forKey: Self.agentKey)
    }
}
