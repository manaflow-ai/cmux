import AppKit
import CmuxSurfaceCatalogModel

extension CloudTreeOutlineView.Coordinator {
    func displayMenuItems(machine: SurfaceMachineID, canCreate: Bool) -> [NSMenuItem] {
        let create = item(String(localized: "cloudTree.menu.newDisplay", defaultValue: "New Display")) { [nodeActions] in
            nodeActions.newDisplay(machine)
        }
        create.isEnabled = canCreate
        if !canCreate { create.toolTip = CloudGuestDisplaySnapshot.unavailableMessage }
        return [create, item(String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")) { [nodeActions] in
            nodeActions.refreshMachine(machine)
        }]
    }
}
