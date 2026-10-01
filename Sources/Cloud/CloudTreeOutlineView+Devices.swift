import CmuxCloud
import AppKit
import CmuxSurfaceCatalogModel
import Foundation

/// One request to expand and select a row, identified by token so SwiftUI
/// re-renders never repeat it.
struct CloudTreeRevealRequest: Equatable {
    let token: UUID
    let nodeID: String

    static func machine(_ machine: SurfaceMachineID) -> CloudTreeRevealRequest {
        CloudTreeRevealRequest(token: UUID(), nodeID: CloudTreeNodeBuilder.nodeID(machine: machine))
    }

    /// Reveals a Cloud workspace by its machine and daemon workspace ids.
    /// Legacy bindings without a remote workspace id fall back to the machine row.
    static func cloudWorkspace(machineID: String, remoteWorkspaceID: String?) -> CloudTreeRevealRequest {
        let machine = SurfaceMachineID.cloud(machineID)
        let workspaceID = remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nodeID = workspaceID.flatMap { value in
            value.isEmpty ? nil : CloudTreeNodeBuilder.nodeID(workspace: value, machine: machine)
        } ?? CloudTreeNodeBuilder.nodeID(machine: machine)
        return CloudTreeRevealRequest(token: UUID(), nodeID: nodeID)
    }

    func path(in nodes: [CloudTreeNode]) -> [CloudTreeNode]? {
        CloudTreeNode.path(to: nodeID, in: nodes)
    }
}

extension CloudTreeOutlineView.Coordinator {
    func deviceDiscoveryMenuItems(section: CloudTreeDevicesSection) -> [NSMenuItem] {
        let actions = nodeActions
        let incomingControl = section.incomingControl
        let discoveryControl = section.discoveryControl
        let incoming = item(incomingControl.title) {
            actions.setDeviceIncomingAccess(!incomingControl.isOn)
        }
        incoming.state = incomingControl.isOn ? .on : .off
        incoming.isEnabled = incomingControl.isEnabled
        let discovery = item(discoveryControl.title) {
            actions.setDeviceDiscovery(!discoveryControl.isOn)
        }
        discovery.state = discoveryControl.isOn ? .on : .off
        discovery.isEnabled = discoveryControl.isEnabled
        return [incoming, discovery]
    }

    /// The context menu of another Mac's row. The verbs are the machine verbs
    /// devices share with cloud machines (New Terminal, New Workspace, Refresh)
    /// plus Copy Device ID; there is deliberately no Checkpoint, Fork, Delete,
    /// Increase Disk, Desktop, or Status: those are cloud control-plane
    /// operations on a VM the account rents, and a Mac on the account has no
    /// equivalent (nothing to fork, nothing to bill, no VNC desktop to show).
    func deviceMenuItems(machine: SurfaceMachineID, canCreate: Bool) -> [NSMenuItem] {
        let nodeActions = nodeActions
        var items: [NSMenuItem] = []
        items.append(item(String(localized: "devices.hide", defaultValue: "Hide from My Devices")) {
            nodeActions.hideDevice(machine)
        })
        items.append(.separator())
        if canCreate {
            items.append(item(String(localized: "cloudTree.menu.newTerminal", defaultValue: "New Terminal")) { nodeActions.newTerminal(machine, nil) })
            items.append(item(String(localized: "cloudTree.menu.newWorkspace", defaultValue: "New Workspace")) { nodeActions.newWorkspace(machine) })
        }
        items.append(item(String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")) { nodeActions.refresh() })
        if let instance = machine.deviceInstance {
            items.append(.separator())
            items.append(item(String(localized: "cloudTree.menu.copyDeviceID", defaultValue: "Copy Device ID")) {
                nodeActions.copyToPasteboard(instance.wireValue)
            })
        }
        return items
    }
}
