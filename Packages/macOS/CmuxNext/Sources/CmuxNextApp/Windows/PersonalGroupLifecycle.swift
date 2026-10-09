import CmuxNextDaemon

/// When a personal workspace group ends (cx-rcby). The home daemon keeps a
/// group until a client deletes it, so the client that moves workspaces
/// owns the rule:
/// - an unpinned group that loses its last live member is deleted (the
///   daemon records the delete in closed history, so Reopen Closed brings it
///   back); a pinned (saved) group stays empty;
/// - New Group on workspaces that already are one whole group makes no
///   second group;
/// - a group made with no member is deleted when its name editor closes
///   while it is still empty.
/// "Live" members are the rows the sidebar can show: a closed workspace
/// keeps its personal row (reopen restores its group) but holds no group open.
nonisolated enum PersonalGroupLifecycle {
    /// A session-qualified workspace, the personal rows' key.
    struct Member: Hashable, Sendable {
        var session: String
        var key: String
    }

    struct Group: Sendable {
        var id: WorkspaceGroupID
        var pinned: Bool
    }

    static func member(_ row: PersonalWorkspace) -> Member {
        Member(session: row.sessionID, key: row.workspaceKey.rawValue)
    }

    /// The unpinned groups that `leaving` leaves with no live member when
    /// they move to `target` (nil: loose, or a new group).
    static func emptied(groups: [Group], rows: [PersonalWorkspace], leaving: Set<Member>, into target: WorkspaceGroupID?,
                        isLive: (Member) -> Bool) -> [WorkspaceGroupID] {
        let sources = Set(rows.filter { leaving.contains(member($0)) }.compactMap(\.group))
        return groups.filter { group in
            !group.pinned && group.id != target && sources.contains(group.id)
                && !rows.contains { $0.group == group.id && !leaving.contains(member($0)) && isLive(member($0)) }
        }.map(\.id)
    }

    /// The group whose live members are exactly `members`, if any.
    static func whole(groups: [Group], rows: [PersonalWorkspace], members: Set<Member>,
                      isLive: (Member) -> Bool) -> WorkspaceGroupID? {
        guard !members.isEmpty else { return nil }
        return groups.first { group in
            Set(rows.filter { $0.group == group.id }.map(member).filter(isLive)) == members
        }?.id
    }

    /// Whether `group` has no live member.
    static func isEmpty(_ group: WorkspaceGroupID, rows: [PersonalWorkspace], isLive: (Member) -> Bool) -> Bool {
        !rows.contains { $0.group == group && isLive(member($0)) }
    }
}

/// The lifecycle rule over the home session's personal state and the
/// machines' trees.
@MainActor
struct PersonalGroupLife {
    let machines: MachineRegistry

    private var personal: PersonalStore { machines.local.store.personal }
    private var groups: [PersonalGroupLifecycle.Group] {
        personal.groups.map { PersonalGroupLifecycle.Group(id: $0.id, pinned: $0.pinned) }
    }

    /// A row is live when its session's tree holds the workspace. A session
    /// this app does not see (another Mac, a disconnected machine) or whose
    /// tree has not loaded counts as live, so no group goes on a guess.
    func isLive(_ member: PersonalGroupLifecycle.Member) -> Bool {
        guard let daemon = machines.daemons.first(where: { $0.store.registryID == member.session }), daemon.store.isLoaded else {
            return true
        }
        return daemon.store.workspaces.contains { ($0.key?.rawValue ?? $0.id) == member.key }
    }

    func members(_ placements: [PersonalSidebarPlanner.Placement]) -> Set<PersonalGroupLifecycle.Member> {
        Set(placements.map { PersonalGroupLifecycle.Member(session: $0.session, key: $0.key.rawValue) })
    }

    /// Groups the move of `placements` into `target` empties.
    func emptied(by placements: [PersonalSidebarPlanner.Placement], into target: WorkspaceGroupID?) -> [WorkspaceGroupID] {
        PersonalGroupLifecycle.emptied(groups: groups, rows: personal.workspaces, leaving: members(placements), into: target,
                                       isLive: isLive)
    }

    /// The group that already is exactly `placements`.
    func whole(_ placements: [PersonalSidebarPlanner.Placement]) -> WorkspaceGroupID? {
        PersonalGroupLifecycle.whole(groups: groups, rows: personal.workspaces, members: members(placements), isLive: isLive)
    }

    /// Whether `group` exists, is unpinned and has no live member.
    func isEmptyUnpinned(_ group: WorkspaceGroupID) -> Bool {
        guard let model = personal.group(group), !model.pinned else { return false }
        return PersonalGroupLifecycle.isEmpty(group, rows: personal.workspaces, isLive: isLive)
    }

    /// Sends one organization command to the home session, then deletes
    /// the groups it `ends`. Until the delete lands an ending group that
    /// shows no member is hidden (`PersonalStore.endingGroups`), so the
    /// emptied group never flashes back between the two commits.
    /// `failed` runs when a command fails (the caller re-syncs).
    func commit(_ label: String, ending: [WorkspaceGroupID], failed: @escaping @MainActor () -> Void,
                _ body: @escaping @Sendable (DaemonConnection) async throws -> Void) {
        let home = machines.local, personal = personal, v2 = home.store.servesStateResources
        personal.endingGroups.formUnion(ending)
        Task {
            defer { personal.endingGroups.subtract(ending) }
            guard await home.request(label, body) != nil else { return failed() }
            guard !ending.isEmpty else { return }
            let deleted = await home.request("delete-personal-group") { connection in
                for group in ending {
                    if v2 { try await connection.state.deleteWorkspaceGroup(group.rawValue) } else { try await connection.deletePersonalGroup(group) }
                }
            }
            if deleted == nil { failed() }
        }
    }

    /// Deletes `group` when it is still an unpinned group with no live member.
    func deleteIfEmpty(_ group: WorkspaceGroupID, failed: @escaping @MainActor () -> Void) {
        guard isEmptyUnpinned(group) else { return }
        commit("delete-personal-group", ending: [group], failed: failed) { _ in }
    }
}

/// One window's group name editors (cx-rcby): the group whose editor opens
/// once the sidebar shows it, and the groups made with no member, which go
/// when their editor closes while they are still empty.
@MainActor
final class PersonalGroupEditorState {
    var pending: WorkspaceGroupID?
    var explicit: Set<WorkspaceGroupID> = []
}
