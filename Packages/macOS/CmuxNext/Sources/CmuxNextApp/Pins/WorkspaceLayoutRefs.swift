import CmuxNextDaemon
import CmuxNextSidebar

/// The one place that converts between a sidebar workspace id
/// (`WorkspaceModel.id`, the durable key) and the layout's workspace ref,
/// the qualified public id `<session>:ws_…` (spec sidebar-sections.md 4,
/// PINNED-ITEMS-END-TO-END amendment 1). Writing refs (pin, Add to Top,
/// drag), resolving them (item info, activation, the list projection) and
/// the legacy pin migration all go through it.
@MainActor
struct WorkspaceLayoutRefs {
    let machines: MachineRegistry

    /// `<session>:<ws_…>`.
    nonisolated static func qualified(session: String, resource: String) -> String { "\(session):\(resource)" }

    /// The session and resource of a qualified value; nil without a colon.
    nonisolated static func split(_ value: String) -> (session: String, resource: String)? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let session = String(value[..<colon]), resource = String(value[value.index(after: colon)...])
        return session.isEmpty || resource.isEmpty ? nil : (session, resource)
    }

    /// The layout ref of a workspace, or nil when its daemon has no
    /// session id or the workspace no resource id (such a workspace cannot
    /// be referenced across devices).
    func ref(for workspace: WorkspaceModel, on daemon: DaemonService) -> LayoutItemRef? {
        guard let session = daemon.store.registryID, let resource = workspace.resourceID?.rawValue else { return nil }
        return .workspace(Self.qualified(session: session, resource: resource))
    }

    /// The layout ref of sidebar workspace `id`.
    func ref(forWorkspace id: String) -> LayoutItemRef? {
        machines.workspace(id: id).flatMap { ref(for: $0.0, on: $0.1) }
    }

    /// The open workspace a ref names, or nil (closed, another device's
    /// session, or not a workspace ref).
    func workspace(for ref: LayoutItemRef) -> (WorkspaceModel, DaemonService)? {
        guard ref.kind == LayoutItemRef.workspaceKind, let (session, resource) = Self.split(ref.value) else { return nil }
        for daemon in machines.daemons where daemon.store.registryID == session {
            if let workspace = daemon.store.workspaces.first(where: { $0.resourceID?.rawValue == resource }) { return (workspace, daemon) }
        }
        return nil
    }

    /// The sidebar workspace id a ref names, or nil.
    func workspaceID(for ref: LayoutItemRef) -> String? { workspace(for: ref)?.0.id }

    /// The workspace a click on a ref selects: the qualified ref's, else a
    /// bare id from an older prototype layout.
    func activationID(for ref: LayoutItemRef) -> String? {
        workspaceID(for: ref) ?? (Self.split(ref.value) == nil ? ref.value : nil)
    }

    /// Sidebar ids of the workspaces the top region shows in `room` (tiles
    /// and top rows), which the workspace list leaves out.
    func topWorkspaceIDs(in layout: SidebarLayoutDocument, room: String?) -> Set<String> {
        let values = layout.topValues(kind: LayoutItemRef.workspaceKind, room: room)
        guard !values.isEmpty else { return [] }
        return Set(values.compactMap { workspaceID(for: .workspace($0)) })
    }
}
