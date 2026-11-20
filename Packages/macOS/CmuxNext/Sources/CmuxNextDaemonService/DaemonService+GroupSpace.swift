package import CmuxNextActions
package import CmuxNextDaemon

extension DaemonService {
    /// A personal group moves its own pins. For a document group, resolve every member before writing any pin.
    package func moveGroupToSpace(_ group: WorkspaceGroupID?, members: [RoomMembership.Workspace?], to room: ProfileID) async -> ActionWorkFailure? {
        if let group {
            return await failure("update-personal-group") { try await $0.updatePersonalGroup(group, room: room) }
        }
        let pins = members.compactMap { $0 }
        guard pins.count == members.count else { return ActionWorkFailure(RefusalStrings.noWorkspaceToActOn) }
        return await failure("pin-workspace") { connection in
            for pin in pins { try await connection.pinWorkspace(session: pin.session, key: WorkspaceKey(rawValue: pin.key), to: room) }
        }
    }
}
