import Foundation

/// The Mac's workspace row and group verbs a phone builds from moves it already sends
/// (verify/parity-mac.md, Workspaces): New Workspace Above / Below / at Top / at Bottom and in
/// Group, Merge Workspace Into…, New Workspace Group and Duplicate Workspace Group.
extension WorkspaceCreator {
    // MARK: New Workspace Above / Below / at Top / at Bottom / in Group

    /// The places the row menu's New Workspace offers next to `workspace`: Above and Below a row
    /// this phone can arrange, at Top and at Bottom of its Mac's sidebar. None for a pinned row
    /// (the Mac orders its pinned tiles with a layout move a phone may not send) or Home.
    public func newWorkspacePlacements(beside workspace: Workspace) -> [NewWorkspacePlacement] {
        guard canArrange(workspace), !workspace.isHome, backend.canCreate(on: workspace.macID) else { return [] }
        var placements: [NewWorkspacePlacement] = []
        if !workspace.isPinned { placements += [.above(workspace.id), .below(workspace.id)] }
        return placements + [.top, .bottom]
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
        let rows = workspaces.enumerated()
            .filter { $0.element.macID == workspace.macID && $0.element.id != workspace.id && !$0.element.isPinned && !$0.element.isHome }
            .sorted { ($0.element.sidebarIndex ?? Int.max, $0.offset) < ($1.element.sidebarIndex ?? Int.max, $1.offset) }
            .map(\.element)
        // Top: before the first loose row. A group shows before the row its `top_index` names, so a
        // new row put at a grouped first row's index would show after that group. Bottom: after the
        // last row, grouped or not (a group's run starts at its first member, so a row after its
        // last member shows after it).
        guard top else { return rows.last }
        return rows.first { $0.group == nil } ?? rows.first
    }

    // MARK: Merge Workspace Into…

    /// The workspaces `workspace` can merge into: its Mac's others, never Home (the Mac's
    /// `WorkspaceMerge.staysPut`), in the Mac's sidebar order.
    public func mergeTargets(for workspace: Workspace) -> [Workspace] {
        guard canManage(workspace), !workspace.isHome, !workspace.tabs.isEmpty, backend.canEditTabs(on: workspace.macID) else { return [] }
        return store.workspaces.enumerated()
            .filter { $0.element.macID == workspace.macID && $0.element.id != workspace.id && !$0.element.isHome && !store.isPending($0.element.id) }
            .sorted { ($0.element.sidebarIndex ?? Int.max, $0.offset) < ($1.element.sidebarIndex ?? Int.max, $1.offset) }
            .map(\.element)
    }

    /// Merge Workspace Into…: every tab of `source` moves into `destination`, one after another
    /// so they keep their order (`move-tab-to-workspace`, as the Mac's `moveTabs`); the emptied
    /// workspace then closes, as on the Mac. Nothing restarts: each tab keeps its terminal, page or chat.
    public func merge(_ source: Workspace, into destination: Workspace) {
        guard !mergeTargets(for: source).isEmpty, destination.macID == source.macID, !destination.isHome else { return }
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
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? MacWorkspaceGroup.newGroupName : trimmed
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
