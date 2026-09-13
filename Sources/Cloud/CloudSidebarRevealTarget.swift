import Foundation

/// A Cloud identity, independent of the selected local workspace or tab.
struct CloudSidebarRevealTarget: Equatable {
    let machine: SurfaceMachineID
    let remoteWorkspaceID: String?
    let resource: SurfaceResourceID?
    let remoteTabID: String?

    init?(
        projection: SurfaceProjection?
    ) {
        guard let projection, projection.resource.machine.cloudMachineID != nil else { return nil }
        machine = projection.resource.machine
        remoteWorkspaceID = projection.remoteWorkspaceID
        resource = projection.resource
        remoteTabID = projection.remoteTabID
    }

    /// Prefer the exact daemon tab, then its workspace, then the machine.
    @MainActor
    func path(in nodes: [CloudTreeNode]) -> [CloudTreeNode]? {
        var best: (score: Int, path: [CloudTreeNode])?
        func visit(_ nodes: [CloudTreeNode], ancestors: [CloudTreeNode]) {
            for node in nodes where node.machine == machine {
                let path = ancestors + [node]
                let score = matchScore(node)
                if score > (best?.score ?? 0) { best = (score, path) }
                visit(node.children, ancestors: path)
            }
        }
        visit(nodes, ancestors: [])
        return best?.path
    }

    @MainActor
    private func matchScore(_ node: CloudTreeNode) -> Int {
        switch node.kind {
        case .machine:
            return 1
        case .workspace(_, let workspace, _, _, _):
            return workspace.id == remoteWorkspaceID ? 2 : 0
        case .terminal(let row):
            return resourceScore(row.resource.id, view: row.remoteView)
        case .browser(let row):
            return resourceScore(row.resource.id, view: row.remoteView)
        case .display(let resource, _, let view):
            return resourceScore(resource.id, view: view)
        default:
            return 0
        }
    }

    private func resourceScore(_ id: SurfaceResourceID, view: SurfaceRemoteView?) -> Int {
        guard id == resource,
              view?.workspace.id == remoteWorkspaceID,
              remoteTabID == nil || view?.tabID == remoteTabID else { return 0 }
        return 3
    }
}
