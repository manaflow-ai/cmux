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
            let openItem = NSMenuItem(
                title: FileExternalOpenText.openInApplication(primaryApplication.displayName),
                action: action,
                keyEquivalent: ""
            )
            openItem.target = target
            openItem.representedObject = FileExplorerExternalOpenRequest(
                fileURL: fileURL,
                applicationURL: primaryApplication.url
            )
            menu.addItem(openItem)

            guard !otherApplications.isEmpty else { return }
            let openWithMenu = NSMenu(title: FileExternalOpenText.openWithMenu)
            for application in otherApplications {
                let appItem = NSMenuItem(
                    title: application.displayName,
                    action: action,
                    keyEquivalent: ""
                )
                appItem.target = target
                appItem.representedObject = FileExplorerExternalOpenRequest(
                    fileURL: fileURL,
                    applicationURL: application.url
                )
                openWithMenu.addItem(appItem)
            }
            let openWithItem = NSMenuItem(title: FileExternalOpenText.openWithMenu, action: nil, keyEquivalent: "")
            openWithItem.submenu = openWithMenu
            menu.addItem(openWithItem)
        } else {
            let openItem = NSMenuItem(
                title: FileExternalOpenText.openExternally,
                action: action,
                keyEquivalent: ""
            )
            openItem.target = target
            openItem.representedObject = FileExplorerExternalOpenRequest(fileURL: fileURL, applicationURL: nil)
            menu.addItem(openItem)
        }
    }
}
