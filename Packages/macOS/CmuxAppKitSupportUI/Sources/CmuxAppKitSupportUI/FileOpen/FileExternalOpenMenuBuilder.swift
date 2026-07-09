public import AppKit
public import Foundation
public import CmuxFoundation

/// Builds the AppKit "Open With / Reveal in Finder" menu for a file.
///
/// Replaces the former `FileExternalOpenMenuFactory` static namespace with a
/// value type holding its injected ``FileExternalOpenMenuStrings`` (resolved
/// app-side) and the ``FileExternalOpenMenuActionTarget`` the produced items
/// point at.
///
/// `NSMenuItem.target` is weak, so the builder retains its action target. Compose
/// one long-lived builder (the app holds a process-wide instance) so the target
/// outlives every menu it wires; constructing a throwaway builder per menu and
/// discarding it would deallocate the target and leave the items unclickable.
public struct FileExternalOpenMenuBuilder {
    private let strings: FileExternalOpenMenuStrings
    private let target: FileExternalOpenMenuActionTarget

    /// Creates a builder.
    /// - Parameters:
    ///   - strings: App-resolved localized titles for the menu.
    ///   - target: The retained `@objc` target the menu items invoke; defaults
    ///     to a fresh ``FileExternalOpenMenuActionTarget`` backed by the shared
    ///     production action.
    public init(
        strings: FileExternalOpenMenuStrings,
        target: FileExternalOpenMenuActionTarget = FileExternalOpenMenuActionTarget()
    ) {
        self.strings = strings
        self.target = target
    }

    /// Builds the external-open menu for `fileURL`.
    ///
    /// The top level is the primary handler ("Open in <app>", or "Open
    /// Externally" when no handler is known) followed by "Reveal in Finder"; the
    /// remaining handlers, when any, go into a trailing "Open With" submenu after
    /// a separator.
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
        item.target = target
        item.representedObject = FileExternalOpenMenuActionPayload(
            fileURL: fileURL,
            action: action
        )
        return item
    }
}
