import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar

// Sidebar organization intents when the home session serves personal state
// (plans/cmux-next/data-model.md 1.2c): groups, group membership and order
// are personal rows in the home daemon, keyed by qualified workspace, and
// are never written to the daemon that owns the workspace. Each intent is
// applied to the sidebar model first (optimistic); the next personal
// snapshot overwrites it with daemon truth, and a rejection re-syncs.
extension SidebarBridge {
    var usesPersonalOrganization: Bool { services.machines.local.store.personal.isLoaded }
    /// The home session places groups among the loose workspaces (`personal-mixed-order-v1`).
    var usesMixedOrder: Bool { services.machines.local.store.supportsPersonalMixedOrder }

    /// Handles an organization intent in personal mode. Returns false for
    /// intents that are not about organization.
    func handlePersonal(_ intent: SidebarIntent) -> Bool {
        guard let state else { return false }
        switch intent {
        case .reorder(let ids, let position):
            let before = model.sections
            placePersonal(ids, at: position, in: before, edit: rows.edits.add(intent)) // pending until the store holds it (cx-odqn)
        case .move(let ids, let group):
            // The drag's rule for every path: a group holds one machine row's workspaces.
            guard SidebarEdits.canMove(ids, toGroup: group, in: model.sections) else { resync(); return true }
            groupFlow.move(ids, into: group, intent)
        case .createGroup(let group, let name, let color, let ids, _, let collapsed, let index):
            // `index` is the group's place among the personal groups (nil, or `Int.max`: last, the daemon's default).
            groupFlow.create(group, name: name, color: color, ids, collapsed: collapsed, room: state.profileID,
                             index: index.flatMap { $0 == .max ? nil : $0 }, intent)
        case .groupEditorEnded(let group):
            groupFlow.editorEnded(WorkspaceGroupID(rawValue: SidebarDocStore.personalGroupID(item: group.rawValue)))
        case .renameGroup(let group, let name):
            groupFlow.edit(group, name: name, intent)
        case .setGroupColor(let group, let color):
            groupFlow.edit(group, color: color, intent)
        case .toggleCollapse(.group(let group)):
            // Each click flips what the sidebar shows now; the fold holds
            // until the store has it, so no echo undoes a click (cx-qno.17).
            guard let shown = model.group(group)?.isCollapsed else { return true }
            let collapsed = !shown, v2 = statePersonal
            rows.fold(group, collapsed: collapsed, on: services.machines.local, failed: saveFailed(intent)) {
                if v2 { return try await $0.state.updateWorkspaceGroup(group.rawValue, collapsed: collapsed) }
                try await $0.updatePersonalGroup(WorkspaceGroupID(rawValue: group.rawValue), collapsed: collapsed)
            }
        case .ungroup(let group):
            // A pending edit until the store has the delete (#26382): the group leaves in this turn, and no
            // live recompute before the delete lands shows it again; a failed delete brings it back and says why.
            let v2 = statePersonal
            personal("delete-personal-group", intent, edit: rows.edits.add(intent)) {
                if v2 { return try await $0.state.deleteWorkspaceGroup(group.rawValue) }
                try await $0.deletePersonalGroup(WorkspaceGroupID(rawValue: group.rawValue))
            }
        case .reorderGroup(let group, _):
            let edit = rows.edits.add(intent)
            // The intent's index counts section nodes; the daemon wants a
            // group-order index (and, mixed, the group's place among the rows).
            let place = PersonalSidebarPlanner(machines: services.machines).groupPlacement(of: group, in: model.sections)
            let v2 = statePersonal, move = place.move, top = place.topIndex
            personal("move-personal-group", intent, edit: edit, until: life.personal.writes.claim(group: group.rawValue, "order")) { connection in
                if let move {
                    if v2 {
                        try await connection.state.moveWorkspaceGroup(group.rawValue, to: move)
                    } else {
                        try await connection.movePersonalGroup(WorkspaceGroupID(rawValue: group.rawValue), to: move)
                    }
                }
                if v2, top != .unchanged { try await connection.state.updateWorkspaceGroup(group.rawValue, topIndex: top) }
            }
        default:
            return false
        }
        return true
    }

    /// Personal order and group for `ids` at `position` in this window's
    /// `sections` (taken before the move): one `set-personal-workspace`
    /// each in the home session; the workspace's own daemon is not written.
    func placePersonal(_ ids: [SidebarWorkspaceID], at position: DropPosition, in sections: [SidebarRowSection],
                       edit: SidebarPendingEdits.Token? = nil) {
        // A position the sidebar document listed names the group by its item (`itm_g_<id>`); the home session
        // knows only the personal id, and an unknown one would take the rows out of their group.
        let group = position.group.map { WorkspaceGroupID(rawValue: SidebarDocStore.personalGroupID(item: $0.rawValue)) }
        // The queue settles a placement that did not apply (the rows show the store's again); `commit` leaves it.
        let settle: @MainActor () -> Void = { [weak self] in
            self?.rows.edits.settle(edit)
            self?.resync()
        }
        // A save that failed says why (#26382); a skipped placement, or one an earlier failure stopped, does not.
        let action = SidebarIntent.reorder(ids, to: position).saveAction
        let report: @MainActor (ActionWorkFailure) -> Void = { [weak self] failure in
            self?.services.registry.reportFailure(of: ActionID(rawValue: action.id), title: action.title, failure)
        }
        let home = services.machines.local, logger = home.logger, queue = services.personalPlacements, claim = life.personal.writes.claim(workspaces: placements(ids).map { ($0.session, $0.key.rawValue) })
        queue.enqueue(on: home, failed: settle) { [weak self] in
            guard let self, let state, services.windows.registry.value.window(state.id)?.isOpen == true,
                  ids.allSatisfy({ services.machines.workspace(id: $0.rawValue) != nil }),
                  let plan = PersonalSidebarPlanner(machines: services.machines).dropPlan(ids, at: position, in: sections) else { return .skipped }
            // `sections` retains this intent's neighbors. The planner now reads
            // personal order containing every successful preceding write.
            let regroup = statePersonal ? plan.regroup : []
            let moving = plan.steps.filter(\.moves).map(\.workspace), life = self.life, writes = life.personal.writes
            let ending = life.emptied(by: moving, into: group)
            let sent = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                var finished = false
                let finish: @MainActor (Bool) -> Void = { ok in
                    guard !finished else { return }
                    finished = true
                    done.resume(returning: ok)
                }
                life.commit("set-personal-workspace", ending: ending, recheck: { ending.filter(life.isEmptyUnpinned) }, until: claim,
                            unanswered: { await queue.releaseHeld(on: home) }, failed: report, completed: { finish($0) }) { sending in
                    for step in plan.steps { // a step a later move took is that move's to send (last write wins)
                        guard await writes.isCurrent(claim, workspace: step.workspace.session, step.workspace.key.rawValue) else { continue }; do {
                            try await SidebarFoldPersist.resending(owner: "sidebar.placementSave", mayHaveApplied: DaemonError.missedDeadline) {
                                try await sending.state.placePersonalWorkspace(session: step.workspace.session, key: step.workspace.key,
                                                                                  resource: step.workspace.resource,
                                                                                  group: step.moves ? (group.map { .set($0) } ?? .clear) : .unchanged,
                                                                                  index: step.index)
                            }
                        } catch let error as DaemonError where error.isWorkspaceNotFound {
                            // The workspace ended after the plan read it (an agent open under load whose half-made workspace
                            // closed): nothing is left to place, and no notice says a move failed (Leo, 2026-11-03).
                            logger.info("personal placement: workspace \(step.workspace.key.rawValue, privacy: .public) is gone; its step is dropped")
                        }
                    }
                    guard let first = plan.first else { return }
                    for id in regroup { try await sending.state.updateWorkspaceGroup(id.rawValue, topIndex: .set(first)) }
                }
            }
            guard sent else { return .failed } // claimed at the move; unanswered or unconnected, `commit` sends it again
            if let connection = home.connection { _ = await home.appliedThroughReply(on: connection, after: "personal placement") }
            rows.edits.settle(edit)
            return .applied
        }
    }

    /// The group lifecycle rule and new groups (cx-rcby).
    var life: PersonalGroupLife { PersonalGroupLife(machines: services.machines) }
    var groupFlow: SidebarGroupFlow { SidebarGroupFlow(bridge: self) }

    /// The home session serves its personal groups as v2 state resources
    /// (`workspace_group.*`, `workspace.place`).
    var statePersonal: Bool { services.machines.local.store.servesStateResources }

    func placements(_ ids: [SidebarWorkspaceID]) -> [PersonalSidebarPlanner.Placement] {
        PersonalSidebarPlanner(machines: services.machines).placements(ids)
    }

    /// Sends one personal-state command for `intent` to the home daemon; a failure
    /// re-syncs the sidebar and says why; a pending `edit` settles (SidebarRows.send).
    private func personal(_ label: String, _ intent: SidebarIntent, edit: SidebarPendingEdits.Token? = nil,
                          until claim: PersonalWriteLedger.Claim? = nil, _ body: @escaping DaemonCommandBody) {
        rows.send(label, edit: edit, on: services.machines.local, until: claim, failed: saveFailed(intent), body)
    }
}
