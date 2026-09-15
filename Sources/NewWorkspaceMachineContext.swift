import Foundation

/// Resolves the machine context captured for one New Workspace invocation.
struct NewWorkspaceMachineContext: Equatable {
    enum Selection: Equatable {
        case none
        case local
        case cloud(String)
        case pending
    }

    enum Target: Equatable {
        case local
        case cloud(String)
        case unavailable
    }

    let target: Target

    init(
        selection: Selection,
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
