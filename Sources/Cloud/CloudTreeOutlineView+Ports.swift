import AppKit
import CmuxCloud
import CmuxSurfaceCatalogModel

extension CloudTreeOutlineView.Coordinator {
    /// The Ports status button's action. It shares the machine's current plan gate.
    func performPortAction(_ action: CloudPortsStatusAction, machineID: SurfaceMachineID) {
        switch action {
        case .none: break
        case .refresh: nodeActions.refreshMachine(machineID)
        case .setupVPN:
            AppDelegate.shared?.openCloudVPNSetup(preferredWindow: outlineView?.window)
        case .openMachine, .openShell:
            // Only opening needs the snapshot: it rejects removed machines and gates expired ones.
            guard let machine = machine(id: machineID) else { return }
            openMachine(machine)
        }
    }

    func openMachine(_ machine: MachineSnapshot) {
        if machine.freeAccess == .expired {
            machineActions.promptUpgrade()
        } else {
            nodeActions.newTerminal(.cloud(machine.id), nil)
        }
    }
}

extension CloudTreeOutlineView.Coordinator {
    /// A Ports row's menu. The first line says who can reach the port; opening
    /// and copying use the private address; Share… is the only way out, and it
    /// starts private (CloudPortShareFlow).
    func portMenuItems(_ resource: SurfaceResource, openAction: @escaping @MainActor () -> Void) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let machineID = resource.machine.cloudMachineID, let port = resource.id.forwardedPort {
            let sharing = CloudPortSharingCache.shared.sharing(machineID: machineID, port: port)
            if sharing == nil { CloudPortSharingCache.shared.refresh(machineID: machineID) }
            let status = NSMenuItem(title: CloudTreePortPresentation.sharingStatus(sharing), action: nil, keyEquivalent: "")
            status.isEnabled = false
            items += [status, .separator()]
        }
        items += [
            item(String(localized: "cloudTree.menu.openPrivatePreview", defaultValue: "Open Private Preview"), action: openAction),
            item(String(localized: "cloudTree.menu.openInNewTab", defaultValue: "Open in New Tab")) { [nodeActions] in
                nodeActions.project(resource.id, .tab, true)
            },
            item(String(localized: "cloudTree.menu.openInNewPane", defaultValue: "Open in New Pane")) { [nodeActions] in
                nodeActions.project(resource.id, .split, false)
            },
            .separator(),
            // Copying the private URL never creates a forward or a publication.
            item(String(localized: "cloudTree.menu.copyPrivateURL", defaultValue: "Copy Private Address URL")) { [nodeActions] in
                nodeActions.copyPortLink(resource.id)
            },
        ]
        if let machineID = resource.machine.cloudMachineID, let port = resource.id.forwardedPort {
            items.append(item(String(localized: "cloudTree.menu.sharePort", defaultValue: "Share\u{2026}")) {
                let label = SurfaceCatalog.shared.machineInfo(for: resource.machine)?.name ?? machineID
                CloudPortShareFlow.present(machineID: machineID, machineLabel: label, port: port)
            })
        }
        items += [
            .separator(),
            item(String(localized: "cloudTree.menu.copySurfaceID", defaultValue: "Copy Surface ID")) { [nodeActions] in
                nodeActions.copyToPasteboard(resource.id.rawValue)
            },
        ]
        return items
    }
}
