import Foundation

/// What one cmux-tui workspace on a cloud machine holds, in the order the
/// sidebar opens and drags it: the terminals in its layout (it views), then its
/// browsers, then the displays it pins. One machine hosts many of these; each
/// is a pointer list into the machine's Terminals group, never a machine of its
/// own. A terminal that left the layout is not in the workspace any more — it
/// lists only in the Terminals group, greyed as detached.
struct CloudTreeRemoteWorkspaceMembers: Equatable {
    var terminals: [SurfaceResource]
    var browsers: [SurfaceResource]
    var displays: [SurfaceResource]

    /// Everything the workspace opens as, in open order.
    var all: [SurfaceResource] { terminals + browsers + displays }
    var ids: [SurfaceResourceID] { all.map(\.id) }
    var isEmpty: Bool { terminals.isEmpty && browsers.isEmpty && displays.isEmpty }

    static let none = CloudTreeRemoteWorkspaceMembers(terminals: [], browsers: [], displays: [])
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

    /// Every workspace's members in ONE pass over the catalog: a resource is
    /// appended to each workspace that views it, so the per-kind lists keep
    /// catalog order. The workspace rows (children and drag group) and the
    /// socket's `vm.workspace_open` both read this, so a click and the CLI open
    /// the same set, and a tree rebuild stays O(resources × views) whatever the
    /// workspace count.
    static func remoteWorkspaceMembersByWorkspace(resources: [SurfaceResource]) -> [String: CloudTreeRemoteWorkspaceMembers] {
        var byWorkspace: [String: CloudTreeRemoteWorkspaceMembers] = [:]
        for resource in resources {
            for workspace in resource.remoteWorkspaces {
                var members = byWorkspace[workspace.id] ?? .none
                switch resource.kind {
                case .terminal: members.terminals.append(resource)
                case .browser: members.browsers.append(resource)
                case .display: members.displays.append(resource)
                }
                byWorkspace[workspace.id] = members
            }
        }
        return byWorkspace
    }

    /// The members of one workspace (an existing workspace nothing views has none).
    static func remoteWorkspaceMembers(workspaceID: String, resources: [SurfaceResource]) -> CloudTreeRemoteWorkspaceMembers {
        remoteWorkspaceMembersByWorkspace(resources: resources)[workspaceID] ?? .none
    }

    /// How many panes of each local workspace show each resource, built once per
    /// tree so every workspace row's open mark is a dictionary read.
    static func projectionIndex(_ snapshot: SurfaceCatalogSnapshot) -> [SurfaceResourceID: [UUID: Int]] {
        var index: [SurfaceResourceID: [UUID: Int]] = [:]
        for projection in snapshot.projections {
            index[projection.resource, default: [:]][projection.workspaceID, default: 0] += 1
        }
        return index
    }

    /// The local workspace that shows a remote workspace: the one holding the most of
    /// its members' panes (at least one). Nil when none of them is open anywhere.
    static func localWorkspaceShowing(_ members: [SurfaceResourceID], projectionIndex: [SurfaceResourceID: [UUID: Int]]) -> UUID? {
        var counts: [UUID: Int] = [:]
        for member in members {
            for (workspaceID, count) in projectionIndex[member] ?? [:] {
                counts[workspaceID, default: 0] += count
            }
        }
        return counts.max { lhs, rhs in lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key.uuidString > rhs.key.uuidString }?.key
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
