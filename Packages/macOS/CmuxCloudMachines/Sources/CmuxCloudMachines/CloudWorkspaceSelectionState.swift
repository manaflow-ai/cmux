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

    /// The workspace identity associated with the last committed navigation.
    /// A provisional machine click intentionally leaves this unchanged until
    /// its local Cloud workspace projection is selected.
    public var trackedWorkspaceID: UUID? { selectedWorkspaceID }

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

    /// Records a Cloud row click before its local workspace projection exists.
    /// The machine remains the shortcut target immediately; a later committed
    /// local selection upgrades this context with its concrete workspace ID.
    public func selectCloudMachine(machineID: String) {
        guard !machineID.isEmpty, let scopeID = scopeProvider(), !scopeID.isEmpty else { return }
        // A row click is a navigation intent even before a local workspace
        // exists. Advance the same fence used by concrete selections so older
        // Cloud creates cannot focus over the newly clicked row.
        revision &+= 1
        lastCloudSelection = CloudWorkspaceSelection(scopeID: scopeID, machineID: machineID)
    }
}
