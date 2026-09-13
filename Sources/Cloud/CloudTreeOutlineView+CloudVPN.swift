import AppKit

extension CloudTreeOutlineView.Coordinator {
    /// Builds the Ports menu while keeping VPN setup on the shared action path.
    func portsGroupMenuItems() -> [NSMenuItem] {
        var items = [
            item(String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")) { [nodeActions] in nodeActions.refresh() },
        ]
        if showsCloudVPNWarning {
            items.append(.separator())
            items.append(item(String(localized: "cloud.ports.vpnOff.setup", defaultValue: "Set Up Cloud VPN")) { [machineActions, window = outlineView?.window] in
                machineActions.setupVPN(window)
            })
        }
        return items
    }
}


extension CloudTreeOutlineView.Coordinator {
    func outlineViewColumnDidResize(_ notification: Notification) {
        guard showsCloudVPNWarning, let outlineView else { return }
        let rows = IndexSet((0..<outlineView.numberOfRows).filter {
            (outlineView.item(atRow: $0) as? CloudTreeNode)?.isPortsEmptyPlaceholder == true
        })
        if !rows.isEmpty { outlineView.noteHeightOfRows(withIndexesChanged: rows) }
    }
}
