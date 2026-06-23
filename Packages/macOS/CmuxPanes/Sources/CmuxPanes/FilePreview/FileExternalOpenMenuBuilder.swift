public import AppKit
public import Foundation

/// The external-open action a menu item carries: open in a specific (or default,
/// when `nil`) application, or reveal in Finder.
enum FileExternalOpenMenuPayloadAction {
    case open(applicationURL: URL?)
    case revealInFinder
}

/// `representedObject` payload attached to each external-open menu item, pairing
/// the target file with the action to perform.
final class FileExternalOpenMenuActionPayload: NSObject {
    let fileURL: URL
    let action: FileExternalOpenMenuPayloadAction

    init(fileURL: URL, action: FileExternalOpenMenuPayloadAction) {
        self.fileURL = fileURL
        self.action = action
    }
}

/// `@objc` target that performs the external-open action stored on a menu item's
/// `representedObject` using the live `FileExternalOpener`.
@MainActor
final class FileExternalOpenMenuActionTarget: NSObject {
    static let shared = FileExternalOpenMenuActionTarget()

    @objc func open(_ item: NSMenuItem) {
        guard let payload = item.representedObject as? FileExternalOpenMenuActionPayload else {
            return
        }
        switch payload.action {
        case .open(let applicationURL):
            guard let applicationURL else {
                FileExternalOpener.live.openDefault(fileURL: payload.fileURL)
                return
            }
            FileExternalOpener.live.open(fileURL: payload.fileURL, applicationURL: applicationURL)
        case .revealInFinder:
            FileExternalOpener.live.revealInFinder(fileURL: payload.fileURL)
        }
    }
}

/// Builds the external-open `NSMenu` for a file: a top-level open/reveal pair,
/// then an "Open With" submenu of the remaining applications.
///
/// Localized titles are injected as a `FileExternalOpenStrings` value (resolved
/// app-side), so this builder performs no localization. This folds the former
/// `FileExternalOpenMenuFactory` caseless namespace-enum onto a real value type.
public struct FileExternalOpenMenuBuilder: Sendable {
    /// Localized menu titles resolved by the app.
    public let strings: FileExternalOpenStrings

    /// Creates a builder using the given localized strings.
    public init(strings: FileExternalOpenStrings) {
        self.strings = strings
    }

    /// Builds the menu for `fileURL`: an "Open in <primary>" (or generic "Open
    /// Externally" when `primaryApplication` is `nil`) item, a "Reveal in
    /// Finder" item, and, when `otherApplications` is non-empty, an "Open With"
    /// submenu listing them.
    @MainActor
    public func makeMenu(
        fileURL: URL,
        primaryApplication: FileExternalOpenApplication?,
        otherApplications: [FileExternalOpenApplication]
    ) -> NSMenu {
        let menu = NSMenu(title: strings.openWithMenu)
        menu.autoenablesItems = false

        if let primaryApplication {
            menu.addItem(menuItem(
                title: strings.openInApplication(primaryApplication.displayName),
                fileURL: fileURL,
                action: .open(applicationURL: primaryApplication.url)
            ))
        } else {
            menu.addItem(menuItem(
                title: strings.openExternally,
                fileURL: fileURL,
                action: .open(applicationURL: nil)
            ))
        }

        menu.addItem(menuItem(
            title: strings.revealInFinder,
            fileURL: fileURL,
            action: .revealInFinder
        ))

        if !otherApplications.isEmpty {
            menu.addItem(.separator())
            let openWithMenu = NSMenu(title: strings.openWithMenu)
            openWithMenu.autoenablesItems = false
            for application in otherApplications {
                openWithMenu.addItem(menuItem(
                    title: application.displayName,
                    fileURL: fileURL,
                    action: .open(applicationURL: application.url)
                ))
            }
            let openWithItem = NSMenuItem(
                title: strings.openWithMenu,
                action: nil,
                keyEquivalent: ""
            )
            openWithItem.submenu = openWithMenu
            menu.addItem(openWithItem)
        }

        return menu
    }

    @MainActor
    private func menuItem(
        title: String,
        fileURL: URL,
        action: FileExternalOpenMenuPayloadAction
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(FileExternalOpenMenuActionTarget.open(_:)),
            keyEquivalent: ""
        )
        item.target = FileExternalOpenMenuActionTarget.shared
        item.representedObject = FileExternalOpenMenuActionPayload(
            fileURL: fileURL,
            action: action
        )
        return item
    }
}
