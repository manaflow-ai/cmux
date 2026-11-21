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
        let membership = RoomMembership(follows: store.personal.follows, pins: store.personal.pinnedRooms)
        let restoredRooms = pins.map { membership.pinned($0) }
        return await failure("pin-workspace") { connection in
            var completed: [Int] = []
            do {
                for (index, pin) in pins.enumerated() {
                    try await connection.pinWorkspace(session: pin.session, key: WorkspaceKey(rawValue: pin.key), to: room)
                    completed.append(index)
                }
            } catch {
                // A later pin can fail after earlier requests succeeded. Restore each completed
                // member to its original pin, or remove the new pin when it was previously loose.
                for index in completed.reversed() {
                    let pin = pins[index]
                    if let previous = restoredRooms[index] {
                        try? await connection.pinWorkspace(session: pin.session, key: WorkspaceKey(rawValue: pin.key), to: previous)
                    } else {
                        try? await connection.unpinWorkspace(session: pin.session, key: WorkspaceKey(rawValue: pin.key))
                    }
                }
                throw error
            }
        }
    }
}
