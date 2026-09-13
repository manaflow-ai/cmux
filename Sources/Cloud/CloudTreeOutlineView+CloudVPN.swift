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
        guard let outlineView else { return }
        updateCloudVPNRowHeights(in: outlineView)
    }

    /// Re-measures wrapping Ports guidance for the resized outline.
    func updateCloudVPNRowHeights(in outlineView: NSOutlineView) {
        guard showsCloudVPNWarning else { return }
        // Snapshot application keeps the retained AppKit item identities. Resolve
        // current indexes here so collapse/expansion never leaves stale row numbers.
        let rows = IndexSet(vpnEmptyPortsNodes.compactMap { node in
            let row = outlineView.row(forItem: node)
            return row >= 0 ? row : nil
        })
        if !rows.isEmpty { outlineView.noteHeightOfRows(withIndexesChanged: rows) }
    }
}
