import CmuxNextAgentPane
import Foundation

/// The new tab screen's Search | Ask mode and the agent last picked, kept on
/// this Mac across relaunches (decision Q3: app-local memory; optional
/// settings may override it later). Client view state, so it never reaches
/// the daemon.
@MainActor
final class NewTabChoiceMemory {
    private static let modeKey = "newTab.lastMode"
    private static let agentKey = "newTab.lastAgent"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var mode: AgentPaneNewTabMode? { defaults.string(forKey: Self.modeKey).flatMap(AgentPaneNewTabMode.init(rawValue:)) }

    var agent: String? { defaults.string(forKey: Self.agentKey).flatMap { $0.isEmpty ? nil : $0 } }

    /// Values the page should never send (an unknown mode, an empty agent) are ignored.
    func remember(mode: String?, agent: String?) {
        if let mode = mode.flatMap(AgentPaneNewTabMode.init(rawValue:)) { defaults.set(mode.rawValue, forKey: Self.modeKey) }
        if let agent, !agent.isEmpty, agent.count <= 128 { defaults.set(agent, forKey: Self.agentKey) }
    }
}
