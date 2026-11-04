import CmuxNextAppCore
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextSidebar
import CmuxNextDesign

/// The lifecycle rule over the home session's personal state and the
/// machines' trees.
@MainActor
struct PersonalGroupLife {
    let machines: MachineRegistry

    var personal: PersonalStore { machines.local.store.personal }
    private var rules: PersonalGroupLifecycle {
        PersonalGroupLifecycle(groups: personal.groups.map { .init(id: $0.id, pinned: $0.pinned) }, rows: personal.workspaces)
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
        rules.emptied(leaving: members(placements), into: target, isLive: isLive)
    }

    /// The group that already is exactly `placements`.
    func whole(_ placements: [PersonalSidebarPlanner.Placement]) -> WorkspaceGroupID? {
        rules.whole(members: members(placements), isLive: isLive)
    }

    /// Whether `group` exists, is unpinned and has no live member.
    func isEmptyUnpinned(_ group: WorkspaceGroupID) -> Bool {
        guard let model = personal.group(group), !model.pinned else { return false }
        return rules.isEmpty(group, isLive: isLive)
    }

    /// Sends one organization command to the home session, then deletes
    /// the groups it `ends`. Until the delete lands an ending group that
    /// shows no member is hidden (`PersonalStore.endingGroups`), so the
    /// emptied group never flashes back between the two commits.
    /// The delete goes only to the groups `recheck` still names once the
    /// command landed, read from the latest personal state: a member
    /// another window or client placed meanwhile keeps its group.
    /// `failed` runs when a command fails, with why (the caller re-syncs and says so).
    /// `applied` runs once the home store holds the command's result
    /// (read-your-writes): a sidebar pending edit settles there (cx-odqn).
    /// `completed` runs last, with whether the command and its cleanup applied.
    /// `landed` gets the command's value as soon as it replied. `until`: sent again while unanswered, never undone.
    func commit<Value: Sendable>(_ label: String, ending: [WorkspaceGroupID], recheck: @escaping @MainActor () -> [WorkspaceGroupID] = { [] },
                                 until claim: PersonalWriteLedger.Claim? = nil, unanswered: (@MainActor () async -> Void)? = nil,
                                 failed: @escaping @MainActor (ActionWorkFailure) -> Void, applied: (@MainActor () -> Void)? = nil,
                                 completed: (@MainActor (Bool) -> Void)? = nil,
                                 landed: @escaping @MainActor (Value) -> Void = { _ in },
                                 _ body: @escaping @Sendable (isolated DaemonConnection) async throws -> Value) {
        let home = machines.local, personal = personal, v2 = home.store.servesStateResources
        personal.endingGroups.formUnion(ending)
        Task {
            // Shown again before a failure re-syncs, so a kept group never stays hidden.
            @MainActor func end() { personal.endingGroups.subtract(ending) }
            let result: (value: Value, completed: Bool)?
            do {
                // `perform`, not `request`: a failure comes back with why, for the caller to say (#26382).
                result = try await home.perform(label, until: claim, unanswered: unanswered) { connection in
                    let value = try await body(connection)
                    // Keep cleanup on the reply's connection and wait for the primary
                    // event before deciding whether the source group is now empty.
                    guard await home.appliedThroughReply(on: connection, after: label) else { throw DaemonError.notConnected }
                    await landed(value)
                    if let applied { await applied() }
                    let still = await MainActor.run { Set(recheck()) }
                    let doomed = ending.filter(still.contains)
                    for group in doomed {
                        if v2 { try await connection.state.deleteWorkspaceGroup(group.rawValue) }
                        else { try await connection.deletePersonalGroup(group) }
                    }
                    return (value: value, completed: true)
                }
            } catch {
                end()
                failed(ActionWorkFailure(label, error))
                completed?(false)
                return
            }
            end()
            if result == nil { applied?() } // superseded: the newer write owns what the rows show
            completed?(result?.completed ?? true)
        }
    }

    /// Deletes `group` when it is still an unpinned group with no live member; `landed` gets whether the delete went and landed.
    func deleteIfEmpty(_ group: WorkspaceGroupID, failed: @escaping @MainActor (ActionWorkFailure) -> Void,
                       landed: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard isEmptyUnpinned(group) else { return landed(false) }
        let life = self, doomed = DeleteSent()
        commit("delete-personal-group", ending: [group], recheck: { doomed.value = life.isEmptyUnpinned(group); return doomed.value ? [group] : [] },
               failed: failed, completed: { landed($0 && doomed.value) }) { _ -> Void in }
    }

    /// Whether a close ends the groups it empties: where Close Workspaces in Group does (`PersonalGroupPin`).
    var endsGroupsOnClose: Bool {
        let home = machines.local
        return personal.isLoaded && home.store.servesStateResources && home.supports(DaemonCapability.workspaceGroupPin.rawValue)
    }

    /// The unpinned personal groups a close of the workspaces `ids` may empty, read before they close.
    func groupsClosing(_ ids: [String]) -> Set<WorkspaceGroupID> {
        guard endsGroupsOnClose else { return [] }
        let closing = Set(ids.compactMap { id in
            WindowProfiles.qualified(id, machines: machines).flatMap { personal.workspace(session: $0.session, key: $0.key)?.group }
        })
        return rules.prunable(closing)
    }

    @MainActor private final class DeleteSent { var value = false }

    /// One close's cleanup of `group`, on the home store and the closed history (`GroupCloseCleanup`).
    func closeCleanup(_ group: WorkspaceGroupID, history: @escaping @MainActor @Sendable () -> [(id: String, group: String?)],
                      failed: @escaping @MainActor @Sendable (ActionWorkFailure) -> Void) -> GroupCloseCleanup {
        let life = self
        return GroupCloseCleanup(group, home: .init(
            exists: { life.personal.group(group) != nil },
            isEmptyUnpinned: { life.isEmptyUnpinned(group) },
            delete: { await withCheckedContinuation { done in life.deleteIfEmpty(group, failed: failed) { done.resume(returning: $0) } } },
            history: history))
    }
}

/// One window's group name editors (cx-rcby): the group whose editor opens
/// once the sidebar shows it, and the groups made with no member, which go
/// when their editor closes while they are still empty.
@MainActor
final class PersonalGroupEditorState {
    var pending: WorkspaceGroupID?
    var explicit: Set<WorkspaceGroupID> = []
    /// Groups the sidebar made that the daemon is still creating: name and
    /// color edits made meanwhile (the editor is open on the new group).
    var creating: [WorkspaceGroupID: [Edit]] = [:]

    /// A name or color edit waiting for the daemon's id, with its pending row edit.
    struct Edit {
        var name: String?
        var color: GroupTint?
        var token: SidebarPendingEdits.Token
    }
    /// The daemon's id for a group the sidebar made under its own id.
    var created: [WorkspaceGroupID: WorkspaceGroupID] = [:]
}
