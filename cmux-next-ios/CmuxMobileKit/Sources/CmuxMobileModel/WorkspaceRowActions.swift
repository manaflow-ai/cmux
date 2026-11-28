import Foundation
#if os(iOS)
import CmuxMobileLinkFFI
#endif

/// The Mac's workspace row and group verbs a phone builds from moves it already sends
/// (verify/parity-mac.md, Workspaces): New Workspace Above / Below / at Top / at Bottom and in
/// Group, Merge Workspace Into…, New Workspace Group and Duplicate Workspace Group.
extension WorkspaceCreator {
    // MARK: New Workspace Above / Below / at Top / at Bottom / in Group

    /// The places the row menu's New Workspace offers next to `workspace`: Above and Below a row
    /// this phone can arrange, at Top and at Bottom of its Mac's sidebar. None for a pinned row
    /// (the Mac orders its pinned tiles with a layout move a phone may not send) or Home.
    public func newWorkspacePlacements(beside workspace: Workspace) -> [NewWorkspacePlacement] {
        #if os(iOS)
        // The rules: Rust's workspace_row_placements (workspace_row_actions.rs).
        workspaceRowPlacements(row: workspace.rowFacts(pending: false), canArrange: canArrange(workspace),
                               canCreate: backend.canCreate(on: workspace.macID)).map { place in
            switch place {
            case .above: .above(workspace.id)
            case .below: .below(workspace.id)
            case .top: .top
            case .bottom: .bottom
            }
        }
        #else
        // Where Rust does not link (the macOS and Linux package builds, which have no phone UI).
        []
        #endif
    }

    /// Places a workspace the Mac just made (`create(…placement:)`): into the anchor's group or
    /// the chosen group first (`workspace.place`), then next to the anchor in the person's order
    /// (`set-personal-workspace {index}`). A refusal leaves it where the Mac put it, and says so.
    func place(_ workspace: Workspace, _ placement: NewWorkspacePlacement) async {
        guard let arranger else { return }
        do {
            switch placement {
            case .inGroup(let group):
                guard let grouper else { throw WorkspaceCreationError("This Mac doesn't group workspaces from a phone", isForPerson: true) }
                try await grouper.place(workspace, in: group)
            case .above(let id), .below(let id):
                guard let anchor = store.workspace(id: id), anchor.macID == workspace.macID else {
                    throw WorkspaceCreationError("That workspace is no longer on the Mac.", isForPerson: true)
                }
                if let group = anchor.group {
                    guard let grouper else { throw WorkspaceCreationError("This Mac doesn't group workspaces from a phone", isForPerson: true) }
                    try await grouper.place(workspace, in: group)
                }
                try await arranger.place(workspace, next: anchor, after: placement == .below(id))
            case .top, .bottom:
                guard let anchor = Self.edgeAnchor(placement == .top, of: workspace, in: store.workspaces) else { return }
                try await arranger.place(workspace, next: anchor, after: placement == .bottom)
            }
        } catch {
            onManageFailure?(workspace, "Couldn't move \(workspace.title) to its place", Self.message(error))
        }
    }

    /// The row a new workspace goes before (top) or after (bottom): the first or last of its Mac's
    /// unpinned rows other than Home and itself, in the Mac's sidebar order. Nil when it is alone.
    nonisolated static func edgeAnchor(_ top: Bool, of workspace: Workspace, in workspaces: [Workspace]) -> Workspace? {
        #if os(iOS)
        // Rust's workspace_new_row_anchor (workspace_row_actions.rs) says which row and why.
        guard let id = workspaceNewRowAnchor(top: top, workspaceId: workspace.id, macId: workspace.macID,
                                           rows: workspaces.map { $0.rowFacts(pending: false) }) else { return nil }
        return workspaces.first { $0.id == id }
        #else
        nil
        #endif
    }

    // MARK: Merge Workspace Into…

    /// The workspaces `workspace` can merge into: its Mac's others, never Home (the Mac's
    /// `WorkspaceMerge.staysPut`), in the Mac's sidebar order.
    public func mergeTargets(for workspace: Workspace) -> [Workspace] {
        guard canMerge(workspace) else { return [] }
        #if os(iOS)
        // Rust's workspace_merge_targets (workspace_row_actions.rs) picks and orders them.
        let rows = store.workspaces
        let ids = workspaceMergeTargets(workspaceId: workspace.id, macId: workspace.macID,
                                        rows: rows.map { $0.rowFacts(pending: store.isPending($0.id)) })
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
        #else
        return []
        #endif
    }

    /// Whether `workspace` may merge into another at all: the phone manages it and edits its
    /// Mac's tabs, it is not Home and it has a tab to move.
    func canMerge(_ workspace: Workspace) -> Bool {
        canManage(workspace) && !workspace.isHome && !workspace.tabs.isEmpty && backend.canEditTabs(on: workspace.macID)
    }

    /// Merge Workspace Into…: every tab of `source` moves into `destination`, one after another
    /// so they keep their order (`move-tab-to-workspace`, as the Mac's `moveTabs`); the emptied
    /// workspace then closes, as on the Mac. Nothing restarts: each tab keeps its terminal, page or chat.
    public func merge(_ source: Workspace, into destination: Workspace) {
        guard canMerge(source), destination.id != source.id, destination.macID == source.macID, !destination.isHome,
              !store.isPending(destination.id) else { return }
        let tabs = source.tabs
        track(source.id) { [weak self] in
            do {
                for tab in tabs {
                    _ = try await self?.backend.moveTab(tab, from: source, toWorkspace: destination)
                }
                // The Mac closes the emptied source itself (`WorkspaceMerge.run`); a source the Mac
                // still lists with no tabs goes the same way. One that keeps tabs the phone does not
                // list stays open.
                // Only when the Mac reports no tab at all: its layout counts the tabs the phone
                // does not list too (a source without a layout stays).
                if let self, let left = store.workspace(id: source.id), left.tabs.isEmpty,
                   left.layout.map({ $0.panes.allSatisfy { $0.tabCount == 0 } }) ?? false {
                    try await backend.close(left)
                }
            } catch {
                self?.onManageFailure?(source, "Couldn't merge \(source.title) into \(destination.title)", Self.message(error))
            }
        }
    }

    // MARK: New Workspace Group, Duplicate Workspace Group

    /// Whether New Workspace Group can make a group on `macID` now.
    public func canCreateGroup(on macID: String) -> Bool {
        grouper != nil && rights(onMac: macID).group
    }

    /// New Workspace Group: an empty group with `name` ("New Group" when none is given) and the
    /// Mac's next color, as the Mac's sidebar makes one (`workspace_group.create`). It shows in
    /// the list once the Mac lists it, ready for New Workspace in Group or Move Workspace to Group.
    public func newGroup(on macID: String, name: String) {
        guard canCreateGroup(on: macID), let grouper else { return }
        let name = MacWorkspaceGroup.chosenName(typed: name)
        let previous = groupRequestTail[macID]
        let task = track("group-\(macID)") { [weak self] in
            await previous?.value
            // The Mac's next color once the group before this one is made (two quick taps differ).
            let color = MacWorkspaceGroup.nextColor(used: Set(grouper.groups(on: macID).compactMap(\.color)))
            do {
                _ = try await grouper.createGroup(named: name, color: color, on: macID)
                self?.groupsRevision += 1
            } catch {
                self?.onGroupFailure?(macID, "Couldn't make the group \(name)", Self.message(error))
            }
        }
        groupRequestTail[macID] = task
    }

    /// Groups of `macID` the phone may use that hold no workspace yet (a New Workspace Group the
    /// Mac listed, or one emptied on the Mac): the list shows each as an empty header.
    public func emptyGroups(on macID: String) -> [MacWorkspaceGroup] {
        _ = groupsRevision
        guard let grouper, rights(onMac: macID).group else { return [] }
        let used = Set(store.workspaces.filter { $0.macID == macID }.compactMap(\.group?.id))
        return grouper.groups(on: macID).filter { !used.contains($0.id) }
    }

    /// Every group `macID` lists to the phone, empty or not (what ``emptyGroups(on:)`` picks from):
    /// a cache of the list keys on it, since a group made or deleted on the Mac moves no revision here.
    public func listedGroups(on macID: String) -> [MacWorkspaceGroup] {
        grouper?.groups(on: macID) ?? []
    }

    /// Delete Group for a group with no workspaces (the members' path needs a member).
    public func deleteEmptyGroup(_ group: MacWorkspaceGroup, on macID: String) {
        guard let grouper, rights(onMac: macID).group else { return }
        let previous = groupRequestTail[macID]
        let task = track("group-\(macID)") { [weak self] in
            await previous?.value
            do {
                try await grouper.deleteGroup(group, on: macID)
                self?.groupsRevision += 1
            } catch {
                self?.onGroupFailure?(macID, "Couldn't delete \(group.displayName)", Self.message(error))
            }
        }
        groupRequestTail[macID] = task
    }

    /// Duplicate Workspace Group: a new group with the same name and color, holding a duplicate
    /// of each member in order (the Mac's `workspaceGroup.duplicate`). Each copy is the phone's
    /// Duplicate Workspace (its terminals as new shells in their folders, its web pages).
    public func duplicateGroup(_ group: MacWorkspaceGroup, on macID: String) {
        let members = members(of: [group], on: macID)
        guard let grouper, let first = members.first, members.allSatisfy({ canDuplicate($0) }) else { return }
        let color = WorkspaceColor(stored: group.color) ?? MacWorkspaceGroup.nextColor(used: Set(grouper.groups(on: macID).compactMap(\.color)))
        let previous = groupRequestTail[macID]
        let task = track(first.id) { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let copy = try await grouper.createGroup(named: group.name, color: color, on: macID)
                for member in members {
                    let duplicate = try await backend.duplicate(member, browsers: true)
                    try await grouper.place(duplicate, in: copy)
                }
            } catch {
                onManageFailure?(first, "Couldn't duplicate \(group.displayName)", Self.message(error))
            }
        }
        groupRequestTail[macID] = task
    }
}

#if os(iOS)
extension Workspace {
    /// What Rust's row rules (workspace_row_actions.rs) read of this row.
    fileprivate func rowFacts(pending: Bool) -> WorkspaceRowFacts {
        WorkspaceRowFacts(id: id, macId: macID, sidebarIndex: sidebarIndex.map(Int64.init), pinned: isPinned,
                          home: isHome, grouped: group != nil, pending: pending)
    }
}
#endif
