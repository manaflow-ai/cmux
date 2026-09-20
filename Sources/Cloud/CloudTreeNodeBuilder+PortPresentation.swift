import CmuxFoundation
import Foundation

extension CloudTreeNodeBuilder {
    static func portChildren(
        machine: SurfaceMachineID,
        info: SurfaceMachineInfo,
        resources: [SurfaceResource],
        projectionIndex: LocalProjectionIndex
    ) -> [CloudTreeNode] {
        var children = resources.map { resource in
            CloudTreeNode(
                id: nodeID(resource: resource.id),
                kind: .port(
                    resource,
                    url: resource.url ?? info.privateAddress.flatMap { address in
                        guard let port = resource.id.forwardedPort ?? resource.port else { return nil }
                        return CmuxInternalHostnames.directPortURL(privateAddress: address, port: port)
                    },
                    openIn: projectionIndex.localWorkspaceShowing(resource: resource.id)
                )
            )
        }
        if !resources.isEmpty, let status = CloudMachineSurfacePresentation.portStatus(info: info) {
            children.append(status)
        }
        return children.isEmpty ? [CloudMachineSurfacePresentation.emptyPorts(info: info)] : children
    }
}
