import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar

// Sidebar intents -> daemon commands, applied optimistically to the
// sidebar model first. The store mapping overwrites the model with daemon
// truth on the next change, so a rejected command reverts by itself; a
// rejection also forces one re-map.
extension SidebarBridge {
    func handle(_ intent: SidebarIntent) {
        switch intent {
        case .select(let id):
            model.apply(intent)
            services.windows.show(workspaceID: id.rawValue, in: state)
        case .reorder(let ids, let position):
            let before = model.sections
            model.apply(intent)
            reorder(ids, to: position, in: before)
        case .rename(let id, let name):
            model.apply(intent)
            guard let key = services.daemon.store.workspaces.first(where: { $0.id == id.rawValue })?.key else { return }
            command("rename-workspace", patch: .renameWorkspace(key: key, name: name)) { c, _ in _ = try await c.renameWorkspace(key, to: name) }
        case .close(let ids):
            model.apply(intent)
            for key in keys(ids) {
                command("close-workspace") { c, _ in _ = try await c.closeWorkspace(key) }
            }
        case .newWorkspace:
            services.windows.newWorkspace(in: state)
        case .setColor(let ids, let color):
            model.apply(intent)
            for key in keys(ids) {
                let update: FieldUpdate<String> = color.map { .set($0.rawValue) } ?? .clear
                command("set-workspace-metadata") { c, _ in _ = try await c.setWorkspaceMetadata(key, color: update) }
            }
        case .toggleCollapse(let target):
            model.apply(intent)
            if case .group(let group) = target, let current = model.group(group) {
                let id = WorkspaceGroupID(rawValue: group.rawValue), collapsed = current.isCollapsed
                command("update-workspace-group", patch: .setWorkspaceGroupCollapsed(id, collapsed: collapsed)) { c, _ in
                    _ = try await c.updateGroup(id, collapsed: collapsed)
                }
            }
        case .createGroup(let group, let name, let color, let ids):
            model.apply(intent)
            let id = WorkspaceGroupID(rawValue: group.rawValue), members = keys(ids)
            command("create-workspace-group") { c, _ in
                _ = try await c.createGroup(name: name, id: id, color: color.rawValue)
                for key in members { _ = try await c.moveWorkspace(key, toGroup: id) }
            }
        case .move(let ids, let group):
            model.apply(intent)
            let id = WorkspaceGroupID(rawValue: group.rawValue)
            for key in keys(ids) { command("move-workspace-to-group") { c, _ in _ = try await c.moveWorkspace(key, toGroup: id) } }
        case .renameGroup(let group, let name):
            model.apply(intent)
            let id = WorkspaceGroupID(rawValue: group.rawValue)
            command("update-workspace-group") { c, _ in _ = try await c.updateGroup(id, name: name) }
        case .setGroupColor(let group, let color):
            model.apply(intent)
            let id = WorkspaceGroupID(rawValue: group.rawValue)
            command("update-workspace-group") { c, _ in _ = try await c.updateGroup(id, color: .set(color.rawValue)) }
        case .ungroup(let group):
            model.apply(intent)
            let id = WorkspaceGroupID(rawValue: group.rawValue)
            command("delete-workspace-group") { c, _ in try await c.deleteGroup(id) }
        case .reorderGroup(let group, let index):
            model.apply(intent)
            let id = WorkspaceGroupID(rawValue: group.rawValue)
            command("move-workspace-group") { c, _ in try await c.moveGroup(id, to: index) }
        case .closeGroup(let group):
            let members = keys(model.group(group)?.workspaces.map(\.id) ?? [])
            model.apply(intent)
            for key in members { command("close-workspace") { c, _ in _ = try await c.closeWorkspace(key) } }
        case .setIcon, .setPinned, .setGroupPinned, .openGroup:
            // Needs daemon fields this build does not map yet; apply locally
            // so the UI responds, the next store change restores truth.
            model.apply(intent)
        }
    }

    private func keys(_ ids: [SidebarWorkspaceID]) -> [WorkspaceKey] {
        let wanted = Set(ids.map(\.rawValue))
        return services.daemon.store.workspaces.filter { wanted.contains($0.id) }.compactMap(\.key)
    }

    private func reorder(_ ids: [SidebarWorkspaceID], to position: DropPosition, in sections: [SidebarRowSection]) {
        guard let root = WorkspaceOrdering.rootIndex(for: position, moving: ids, in: sections) else { return }
        for (offset, key) in keys(ids).enumerated() {
            let index = root + offset
            if let group = position.group {
                let groupID = WorkspaceGroupID(rawValue: group.rawValue)
                command("move-workspace-to-group") { c, _ in _ = try await c.moveWorkspace(key, toGroup: groupID, index: index) }
            } else {
                command("move-workspace", patch: .moveWorkspace(key: key, index: index)) { c, _ in _ = try await c.moveWorkspace(key, to: index) }
            }
        }
    }

    private func command(_ label: String, patch: OptimisticPatch = .custom { _ in },
                         _ body: @escaping @Sendable (DaemonConnection, ClientTransactionID) async throws -> Void) {
        Task {
            let ok = await services.daemon.perform(label, patch: patch, body)
            if !ok {
                model.sections = SidebarMapping.sections(services.daemon.store.sidebarSections, machine: model.sections.first?.machine
                    ?? SidebarMachine(id: .local, name: Strings.localMachine, kind: .local))
            }
        }
    }
}
