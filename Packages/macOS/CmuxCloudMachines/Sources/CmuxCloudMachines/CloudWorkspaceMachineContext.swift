import Foundation

/// Selection state captured by a window before starting a New Workspace action.
public enum CloudWorkspaceMachineSelection: Equatable, Sendable {
    /// No Machines row is selected.
    case none
    /// This Mac is selected.
    case local
    /// A Cloud machine row or descendant is selected.
    case cloud(String)
    /// A pending machine row is selected and cannot accept a workspace yet.
    case pending
}

/// Resolves a window's current selection into a fail-closed workspace target.
public struct CloudWorkspaceMachineContext: Equatable, Sendable {
    /// The target selected for New Workspace.
    public enum Target: Equatable, Sendable {
        /// Create on this Mac.
        case local
        /// Create on this Cloud machine id.
        case cloud(String)
        /// The selected Cloud row cannot accept creation.
        case unavailable
    }

    /// The resolved target.
    public let target: Target

    /// Resolves the focused Machines selection before an async operation starts.
    /// - Parameters:
    ///   - selection: The complete Machines tree selection snapshot.
    ///   - selectedWorkspaceCloudMachineID: The selected workspace's Cloud binding.
    ///   - machinesPanelOwnsFocus: Whether the Machines panel owns window focus.
    public init(
        selection: CloudWorkspaceMachineSelection,
        selectedWorkspaceCloudMachineID: String?,
        machinesPanelOwnsFocus: Bool
    ) {
        if machinesPanelOwnsFocus {
            switch selection {
            case .cloud(let id) where !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                target = .cloud(id.trimmingCharacters(in: .whitespacesAndNewlines))
            case .local:
                target = .local
            case .pending:
                target = .unavailable
            case .none, .cloud:
                target = Self.workspaceTarget(selectedWorkspaceCloudMachineID)
            }
        } else {
            target = Self.workspaceTarget(selectedWorkspaceCloudMachineID)
        }
    }

    private static func workspaceTarget(_ value: String?) -> Target {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? .cloud(value!) : .local
    }
}
