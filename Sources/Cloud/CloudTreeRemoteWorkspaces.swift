import Foundation

/// What one cmux-tui workspace on a cloud machine holds, in the order the
/// sidebar opens and drags it: the terminals it views, then its browsers, then
/// the displays it pins. One machine hosts many of these; each is a pointer
/// list into the machine's pools, never a machine of its own.
struct CloudTreeRemoteWorkspaceMembers: Equatable {
    var terminals: [SurfaceResource]
    var browsers: [SurfaceResource]
    var displays: [SurfaceResource]

    /// Everything the workspace opens as, in open order.
    var all: [SurfaceResource] { terminals + browsers + displays }
    var ids: [SurfaceResourceID] { all.map(\.id) }
    var isEmpty: Bool { terminals.isEmpty && browsers.isEmpty && displays.isEmpty }
}

/// How a `<workspace>` selector resolves on a machine — the one answer shared
/// by the sidebar row, the socket's `vm.workspace_open`, and `cmux vm open
/// <machine>/<workspace>`.
enum CloudTreeRemoteWorkspaceLookup: Equatable {
    /// Exactly one workspace matched; `members` is what it opens as (an existing
    /// workspace with nothing in it resolves here with empty members).
    case found(SurfaceRemoteWorkspace, CloudTreeRemoteWorkspaceMembers)
    /// Several workspaces carry the selector as their name; only a `ws_…` id
    /// picks one.
    case ambiguous([SurfaceRemoteWorkspace])
    case notFound
}

extension CloudTreeNodeBuilder {
    /// Every cmux-tui workspace on a machine, in the daemon's order: the ones the
    /// machine itself reports (so an empty workspace still gets a row) plus any
    /// that a resource's views name before the machine list has caught up.
    static func remoteWorkspaces(info: SurfaceMachineInfo?, resources: [SurfaceResource]) -> [SurfaceRemoteWorkspace] {
        var byID: [String: SurfaceRemoteWorkspace] = [:]
        for workspace in info?.remoteWorkspaces ?? [] {
            byID[workspace.id] = workspace
        }
        for resource in resources {
            for workspace in resource.remoteWorkspaces where byID[workspace.id] == nil {
                byID[workspace.id] = workspace
            }
        }
        return byID.values.sorted { lhs, rhs in
            lhs.index != rhs.index ? lhs.index < rhs.index : lhs.id < rhs.id
        }
    }

    static func remoteWorkspaces(on machine: SurfaceMachineID, snapshot: SurfaceCatalogSnapshot) -> [SurfaceRemoteWorkspace] {
        remoteWorkspaces(info: snapshot.machines.first { $0.id == machine }, resources: snapshot.resources(on: machine))
    }

    /// The members of one workspace: every resource with a view in it, by kind,
    /// in catalog order. The workspace row's children and drag group and the
    /// socket's `vm.workspace_open` all read this, so a click and the CLI open
    /// the same set.
    static func remoteWorkspaceMembers(workspaceID: String, resources: [SurfaceResource]) -> CloudTreeRemoteWorkspaceMembers {
        let viewed = resources.filter { resource in resource.remoteWorkspaces.contains { $0.id == workspaceID } }
        return CloudTreeRemoteWorkspaceMembers(
            terminals: viewed.filter { $0.kind == .terminal },
            browsers: viewed.filter { $0.kind == .browser },
            displays: viewed.filter { $0.kind == .display }
        )
    }

    /// Resolves `selector` — a `ws_…` id, or a workspace name when exactly one
    /// workspace on the machine carries it — against the catalog.
    static func lookupRemoteWorkspace(_ selector: String, on machine: SurfaceMachineID, snapshot: SurfaceCatalogSnapshot) -> CloudTreeRemoteWorkspaceLookup {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notFound }
        let resources = snapshot.resources(on: machine)
        let workspaces = remoteWorkspaces(info: snapshot.machines.first { $0.id == machine }, resources: resources)
        if let byID = workspaces.first(where: { $0.id == trimmed }) {
            return .found(byID, remoteWorkspaceMembers(workspaceID: byID.id, resources: resources))
        }
        let byName = workspaces.filter { $0.name == trimmed }
        switch byName.count {
        case 0:
            return .notFound
        case 1:
            return .found(byName[0], remoteWorkspaceMembers(workspaceID: byName[0].id, resources: resources))
        default:
            return .ambiguous(byName)
        }
    }
}
