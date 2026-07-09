import AppKit
import CmuxFoundation

/// Represented-object payload for a file-explorer "Open in <app>" menu item.
///
/// Carries the file to open plus the resolved application URL (nil means "let
/// the system pick the default handler"). The external-open `@objc` action reads
/// this back off `NSMenuItem.representedObject`.
final class FileExplorerExternalOpenRequest: NSObject {
    let fileURL: URL
    let applicationURL: URL?

    init(fileURL: URL, applicationURL: URL?) {
        self.fileURL = fileURL
        self.applicationURL = applicationURL
    }
}

extension NSMenu {
    /// Append the external-open items for `fileURL` (primary handler, an
    /// "Open With" submenu of the remaining handlers, or a single "Open
    /// Externally" fallback when no handler is known).
    func addFileExplorerExternalOpenItems(
        fileURL: URL,
        target: AnyObject,
        action: Selector
    ) {
        let text = FileExternalOpenText()
        let applications = FileExternalOpenApplicationResolver.live.applications(for: fileURL)
        let primaryApplication = applications.first { $0.isDefault } ?? applications.first
        let otherApplications = applications.filter { application in
            application.id != primaryApplication?.id
        }

        if let primaryApplication {
            let openItem = NSMenuItem(
                title: text.openInApplication(primaryApplication.displayName),
                action: action,
                keyEquivalent: ""
            )
            openItem.target = target
            openItem.representedObject = FileExplorerExternalOpenRequest(
                fileURL: fileURL,
                applicationURL: primaryApplication.url
            )
            addItem(openItem)

            guard !otherApplications.isEmpty else { return }
            let openWithMenu = NSMenu(title: text.openWithMenu)
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
            let openWithItem = NSMenuItem(title: text.openWithMenu, action: nil, keyEquivalent: "")
            openWithItem.submenu = openWithMenu
            addItem(openWithItem)
        } else {
            let openItem = NSMenuItem(
                title: text.openExternally,
                action: action,
                keyEquivalent: ""
            )
            openItem.target = target
            openItem.representedObject = FileExplorerExternalOpenRequest(fileURL: fileURL, applicationURL: nil)
            addItem(openItem)
        }
    }
}
