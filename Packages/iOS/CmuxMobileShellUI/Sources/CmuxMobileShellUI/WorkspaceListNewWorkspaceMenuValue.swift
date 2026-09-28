struct WorkspaceListNewWorkspaceMenuValue: Equatable {
    /// A Cloud machine the menu can create a workspace on directly.
    struct CloudTarget: Equatable, Identifiable {
        let hostID: String
        let name: String
        let isConnected: Bool
        var id: String { hostID }
    }

    let canCreate: Bool
    let canCreateGroup: Bool
    /// Cloud machines offered as create targets under All Computers; empty
    /// when the list is scoped to one computer.
    var cloudTargets: [CloudTarget] = []

    var isEnabled: Bool { canCreate || cloudTargets.contains(where: \.isConnected) }
}
