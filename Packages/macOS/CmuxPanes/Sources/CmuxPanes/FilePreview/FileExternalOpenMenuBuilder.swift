public import AppKit
public import Foundation

/// The external-open action a menu item carries: open in a specific (or default,
/// when `nil`) application, or reveal in Finder.
public enum FileExternalOpenMenuPayloadAction {
    case open(applicationURL: URL?)
    case revealInFinder
}

/// `representedObject` payload attached to each external-open menu item, pairing
/// the target file with the action to perform.
public final class FileExternalOpenMenuActionPayload: NSObject {
    /// The file the action targets.
    public let fileURL: URL
    /// The action to perform on `fileURL`.
    public let action: FileExternalOpenMenuPayloadAction

    /// Creates a payload pairing `fileURL` with `action`.
    public init(fileURL: URL, action: FileExternalOpenMenuPayloadAction) {
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

    /// Appends the external-open items for `fileURL` into an existing `menu`,
    /// routing each item to a caller-supplied `target`/`action` rather than the
    /// builder's own shared target.
    ///
    /// This is the faithful append variant used by context menus that own their
    /// own delegate (`@objc` selectors) and assemble a larger menu around the
    /// external-open items. It mirrors `makeMenu`'s app-selection rules: the
    /// default application (or the first, when none is default) becomes the
    /// top-level "Open in <app>" item, the remaining applications go in an "Open
    /// With" submenu, and when no applications resolve it appends a single
    /// generic "Open Externally" item. Unlike `makeMenu` it appends no "Reveal
    /// in Finder" item and no separator; the caller owns those.
    ///
    /// Each appended item carries a ``FileExternalOpenMenuActionPayload`` with an
    /// `.open(applicationURL:)` action as its `representedObject`, so the
    /// caller's `action` reads the file/application pair from
    /// `sender.representedObject`.
    @MainActor
    public func appendExternalOpenItems(
        to menu: NSMenu,
        fileURL: URL,
        applications: [FileExternalOpenApplication],
        target: AnyObject,
        action: Selector
    ) {
        let primaryApplication = applications.first { $0.isDefault } ?? applications.first
        let otherApplications = applications.filter { application in
            application.id != primaryApplication?.id
        }

        if let primaryApplication {
            menu.addItem(callerMenuItem(
                title: strings.openInApplication(primaryApplication.displayName),
                fileURL: fileURL,
                applicationURL: primaryApplication.url,
                target: target,
                action: action
            ))

            guard !otherApplications.isEmpty else { return }
            let openWithMenu = NSMenu(title: strings.openWithMenu)
            for application in otherApplications {
                openWithMenu.addItem(callerMenuItem(
                    title: application.displayName,
                    fileURL: fileURL,
                    applicationURL: application.url,
                    target: target,
                    action: action
                ))
            }
            let openWithItem = NSMenuItem(title: strings.openWithMenu, action: nil, keyEquivalent: "")
            openWithItem.submenu = openWithMenu
            menu.addItem(openWithItem)
        } else {
            menu.addItem(callerMenuItem(
                title: strings.openExternally,
                fileURL: fileURL,
                applicationURL: nil,
                target: target,
                action: action
            ))
        }
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

    @MainActor
    private func callerMenuItem(
        title: String,
        fileURL: URL,
        applicationURL: URL?,
        target: AnyObject,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = FileExternalOpenMenuActionPayload(
            fileURL: fileURL,
            action: .open(applicationURL: applicationURL)
        )
        return item
    }
}
