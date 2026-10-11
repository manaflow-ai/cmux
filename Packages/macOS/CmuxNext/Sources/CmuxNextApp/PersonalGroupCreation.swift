import CmuxNextDaemon

/// What a new personal group still needs after the daemon names it: its
/// place among the loose rows (`personal-mixed-order-v1`) and, for an undo
/// of Ungroup (cx-qno.17), its collapsed state. Kept beside SidebarBridge so
/// the bridge type stays under the god-file limit.
enum PersonalGroupCreation {
    static func finish(_ created: WorkspaceGroupID, topIndex: FieldUpdate<Int>, collapsed: Bool, statePersonal v2: Bool,
                       on connection: DaemonConnection) async throws {
        if topIndex != .unchanged { try await connection.state.updateWorkspaceGroup(created.rawValue, topIndex: topIndex) }
        guard collapsed else { return }
        if v2 {
            try await connection.state.updateWorkspaceGroup(created.rawValue, collapsed: true)
        } else {
            try await connection.updatePersonalGroup(created, collapsed: true)
        }
    }
}
