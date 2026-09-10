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
    /// The context menu of another Mac's row. The verbs are the machine verbs
    /// devices share with cloud machines (New Terminal, New Workspace, Refresh)
    /// plus Copy Device ID; there is deliberately no Checkpoint, Fork, Delete,
    /// Increase Disk, Desktop, or Status: those are cloud control-plane
    /// operations on a VM the account rents, and a Mac on the account has no
    /// equivalent (nothing to fork, nothing to bill, no VNC desktop to show).
    func deviceMenuItems(machine: SurfaceMachineID, canCreate: Bool) -> [NSMenuItem] {
        let nodeActions = nodeActions
        var items: [NSMenuItem] = []
        // An unpaired Mac never gets a credentialed dial from the tree: the one
        // verb it offers routes to the pairing flow in Settings › Computers.
        let needsPairing = nodeActions.needsDevicePairing(machine)
        if needsPairing {
            items.append(item(String(localized: "cloudTree.menu.pairInSettings", defaultValue: "Pair in Settings \u{203A} Computers\u{2026}")) {
                SettingsWindowPresenter.show(navigationTarget: .computers)
            })
            items.append(.separator())
        }
        if canCreate, !needsPairing {
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
