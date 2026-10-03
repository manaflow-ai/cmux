import CmuxCloud
import AppKit
import CmuxSurfaceCatalogModel

extension CloudTreeOutlineView.Coordinator {
    func displayMenuItems(machine: SurfaceMachineID, canCreate: Bool) -> [NSMenuItem] {
        let create = item(String(localized: "cloudTree.menu.newDisplay", defaultValue: "New Display")) { [nodeActions] in
            nodeActions.newDisplay(machine)
        }
        create.isEnabled = true
        create.toolTip = String(localized: "cloudTree.menu.newDisplay", defaultValue: "New Display")
        return [create, item(String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")) { [nodeActions] in
            nodeActions.refreshMachine(machine)
        }]
    }
}
