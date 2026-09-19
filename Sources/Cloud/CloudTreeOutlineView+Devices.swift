import AppKit
import Foundation

/// One request to expand and select a row, identified by token so SwiftUI
/// re-renders never repeat it.
struct CloudTreeRevealRequest: Equatable {
    let token: UUID
    let nodeID: String

    static func machine(_ machine: SurfaceMachineID) -> CloudTreeRevealRequest {
        CloudTreeRevealRequest(token: UUID(), nodeID: CloudTreeNodeBuilder.nodeID(machine: machine))
    }

    func path(in nodes: [CloudTreeNode]) -> [CloudTreeNode]? {
        for node in nodes {
            if node.id == nodeID { return [node] }
            if let descendants = path(in: node.children) { return [node] + descendants }
        }
        return nil
    }
}

extension CloudTreeOutlineView.Coordinator {
    func deviceDiscoveryMenuItems(section: CloudTreeDevicesSection) -> [NSMenuItem] {
        let actions = nodeActions
        let incoming = item(String(localized: "devices.incoming.toggle", defaultValue: "Make this Mac discoverable")) {
            actions.setDeviceIncomingAccess(!section.incomingAccessEnabled)
        }
        incoming.state = section.incomingAccessEnabled && !section.incomingAccessManaged ? .on : .off
        incoming.isEnabled = !section.incomingAccessManaged
        let discovery = item(String(localized: "devices.discovery.toggle", defaultValue: "Discover other Macs")) {
            actions.setDeviceDiscovery(!section.discoveryEnabled)
        }
        discovery.state = section.discoveryEnabled && !section.discoveryManaged ? .on : .off
        discovery.isEnabled = !section.discoveryManaged
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
