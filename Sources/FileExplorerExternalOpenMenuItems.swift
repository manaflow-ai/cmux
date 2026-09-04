import AppKit
import Foundation

struct FileExplorerExternalOpenMenuItems {
    let fileURL: URL
    let target: AnyObject
    let action: Selector

    func add(to menu: NSMenu) {
        let applications = FileExternalOpenApplicationResolver.live.applications(for: fileURL)
        let primaryApplication = applications.first { $0.isDefault } ?? applications.first
        let otherApplications = applications.filter { application in
            application.id != primaryApplication?.id
        }

        if let primaryApplication {
            menu.addItem(menuItem(
                title: FileExternalOpenText.openInApplication(primaryApplication.displayName),
                requestAction: .open(applicationURL: primaryApplication.url)
            ))
        } else {
            menu.addItem(menuItem(
                title: FileExternalOpenText.openExternally,
                requestAction: .open(applicationURL: nil)
            ))
        }

        let openWithMenu = NSMenu(title: FileExternalOpenText.openWithMenu)
        for application in otherApplications {
            openWithMenu.addItem(menuItem(
                title: application.displayName,
                requestAction: .open(applicationURL: application.url)
            ))
        }
        if !otherApplications.isEmpty {
            openWithMenu.addItem(.separator())
        }
        // Always offered, so a file can reach an application Launch Services
        // does not associate with it.
        openWithMenu.addItem(menuItem(
            title: FileExternalOpenText.openWithOther,
            requestAction: .pickApplication
        ))

        let openWithItem = NSMenuItem(title: FileExternalOpenText.openWithMenu, action: nil, keyEquivalent: "")
        openWithItem.submenu = openWithMenu
        menu.addItem(openWithItem)
    }

    private func menuItem(title: String, requestAction: FileExternalOpenRequestAction) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = FileExternalOpenRequest(fileURL: fileURL, action: requestAction)
        return item
    }
}
