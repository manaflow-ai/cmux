import Foundation

/// Remembers Cloud selection for one window while local navigation leaves it intact.
@MainActor
public final class CloudWorkspaceSelectionState {
    private let scopeProvider: @MainActor () -> String?
    private var selectedWorkspaceID: UUID?
    /// The latest Cloud selection; its scope and live workspace must be validated when used.
    public private(set) var lastCloudSelection: CloudWorkspaceSelection?
    /// Changes on navigation so asynchronous creation cannot replace a newer selection.
    public private(set) var revision: UInt64 = 0

    /// Creates window-owned selection state using the app's authenticated scope.
    /// - Parameter scopeProvider: The same account/team source used by the machine sidebar.
    public init(scopeProvider: @escaping @MainActor () -> String?) {
        self.scopeProvider = scopeProvider
    }

    /// Records committed selection or a Cloud binding arriving for the selected workspace.
    /// - Parameters:
    ///   - workspaceID: The selected local workspace identity, or nil for no selection.
    ///   - machineID: Its Cloud machine; nil for an ordinary local workspace.
    public func select(workspaceID: UUID?, machineID: String?) {
        if selectedWorkspaceID != workspaceID {
            revision &+= 1
            selectedWorkspaceID = workspaceID
        }
        guard let workspaceID, let machineID, !machineID.isEmpty,
              let scopeID = scopeProvider(), !scopeID.isEmpty else { return }
        lastCloudSelection = CloudWorkspaceSelection(workspaceID: workspaceID, scopeID: scopeID, machineID: machineID)
    }
}
