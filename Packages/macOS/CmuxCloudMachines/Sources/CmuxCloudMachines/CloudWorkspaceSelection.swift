import Foundation

/// The Cloud workspace selected in one window and authenticated account/team.
public struct CloudWorkspaceSelection: Equatable, Sendable {
    /// The local workspace whose Cloud binding supplies the machine.
    public let workspaceID: UUID
    /// The authenticated account/team that owns the selection.
    public let scopeID: String
    /// The immutable Cloud machine identity.
    public let machineID: String

    /// Captures a Cloud selection without persisting a routing preference.
    /// - Parameters:
    ///   - workspaceID: The selected local workspace.
    ///   - scopeID: The authenticated account/team scope.
    ///   - machineID: The workspace's Cloud machine.
    public init(workspaceID: UUID, scopeID: String, machineID: String) {
        self.workspaceID = workspaceID
        self.scopeID = scopeID
        self.machineID = machineID
    }
}
