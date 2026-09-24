import Foundation

/// Agent integrations whose lifecycle includes an explicit hook installation step.
public enum AgentIntegrationInstallTarget: String, CaseIterable, Hashable, Sendable {
    case amp
}

/// Read-only state reported by the authoritative hook installer.
public enum AgentIntegrationInstallState: String, Codable, Equatable, Sendable {
    case checking
    case missing
    case installed
    case stale
    case conflict
    case unavailable
}

/// User actions Settings can offer for a hook-managed integration.
public enum AgentIntegrationInstallAction: String, CaseIterable, Hashable, Sendable {
    case install
    case repair
    case remove
    case openInstructions
}

/// State rendered by Settings after combining the persisted enablement toggle
/// with the installer-owned on-disk state.
public enum AgentIntegrationDisplayState: Equatable, Sendable {
    case checking
    case disabled
    case missing
    case installed
    case stale
    case conflict
    case unavailable
}

/// Pure state-to-actions mapping used by the Settings UI.
public struct AgentIntegrationPresentation: Equatable, Sendable {
    public let displayState: AgentIntegrationDisplayState
    public let availableActions: [AgentIntegrationInstallAction]

    public init(isEnabled: Bool, installState: AgentIntegrationInstallState) {
        switch installState {
        case .checking:
            displayState = .checking
        case .conflict:
            displayState = .conflict
        case .unavailable:
            displayState = .unavailable
        case .missing:
            displayState = isEnabled ? .missing : .disabled
        case .installed:
            displayState = isEnabled ? .installed : .disabled
        case .stale:
            displayState = isEnabled ? .stale : .disabled
        }

        switch installState {
        case .checking:
            availableActions = []
        case .missing:
            availableActions = [.install, .openInstructions]
        case .installed:
            availableActions = [.remove, .openInstructions]
        case .stale:
            availableActions = [.repair, .remove, .openInstructions]
        case .conflict, .unavailable:
            availableActions = [.openInstructions]
        }
    }
}

/// Result of an installer action dispatched through the host app.
public struct AgentIntegrationActionResult: Equatable, Sendable {
    public let succeeded: Bool
    public let message: String?

    public init(succeeded: Bool, message: String? = nil) {
        self.succeeded = succeeded
        self.message = message
    }

    public static let success = AgentIntegrationActionResult(succeeded: true)
}
