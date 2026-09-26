import CmuxCloud
import CmuxFoundation
import CmuxSurfaceCatalogModel
import Foundation

extension CloudTreeNodeBuilder {
    static func portChildren(
        machine: SurfaceMachineID,
        info: SurfaceMachineInfo,
        resources: [SurfaceResource],
        projectionIndex: LocalProjectionIndex,
        showsCloudVPNWarning: Bool = false
    ) -> [CloudTreeNode] {
        var children = resources.filter { $0.machine == machine }.map { resource in
            CloudTreeNode(
                id: nodeID(resource: resource.id),
                kind: .port(
                    resource,
                    url: info.privateAddress.flatMap { address in
                        guard resource.machine == machine else { return nil }
                        switch CloudPortRoutePlan.plan(resource: resource, privateAddress: address) {
                        case .privateDirect(let url): return url
                        case .unsupported: return nil
                        }
                    },
                    openIn: projectionIndex.localWorkspaceShowing(resource: resource.id)
                )
            )
        }
        if !resources.isEmpty, let status = CloudMachineSurfacePresentation.portStatus(info: info) {
            children.append(status)
        }
        if children.isEmpty {
            children.append(CloudMachineSurfacePresentation.emptyPorts(info: info))
        }
        // SSH ports ride the SSH link's loopback forward; the Cloud VPN never reaches them.
        if showsCloudVPNWarning, !machine.isSSH, info.linkState == .connected || info.linkState == .notApplicable {
            children.append(CloudTreeNode(
                id: "machine:\(machine.rawValue)/ports/vpn-guidance",
                kind: .placeholder(
                    machine: machine,
                    CloudTreePlaceholder(
                        text: CloudPortsStatusPresentation.vpnGuidance.title,
                        style: CloudPortsStatusPresentation.vpnGuidance.style,
                        portStatus: CloudPortsStatusPresentation.vpnGuidance
                    )
                )
            ))
        }
        return children
    }
}
