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
    /// and copying use the private address; the Share submenu is the only way
    /// out, built by the same `CloudPortShareFlow.menuItems` as the preview
    /// tab's share control, so it starts private and asks before going public.
    func portMenuItems(_ resource: SurfaceResource, openAction: @escaping @MainActor () -> Void) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let context = CloudTreePortPresentation(resource: resource).shareTarget.map { target in
            CloudPortShareContext(
                machineID: target.machineID,
                machineLabel: SurfaceCatalog.shared.machineInfo(for: resource.machine)?.name ?? target.machineID,
                port: target.port
            )
        }
        if let context {
            let store = CloudPortSharingStore.shared
            store.requestRefresh()
            let sharing = store.sharing(machineID: context.machineID, port: context.port)
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
        if let context {
            let share = NSMenuItem(title: String(localized: "cloudTree.menu.share", defaultValue: "Share"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            // The submenu repeats the status line; the row menu already shows it.
            for entry in CloudPortShareFlow.menuItems(context).dropFirst(2) { submenu.addItem(entry) }
            share.submenu = submenu
            items.append(share)
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
