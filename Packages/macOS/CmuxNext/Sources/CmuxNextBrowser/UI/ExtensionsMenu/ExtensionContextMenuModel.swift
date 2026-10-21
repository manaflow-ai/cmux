import AppKit

/// One extension's context menu, in the order of Chrome's legacy `ExtensionContextMenuModel`
/// (`chrome/browser/extensions/extension_context_menu_model.cc`, `InitMenu`): the extension's
/// name (its home page), the site-access entry, Options, Remove, Pin or Unpin, then Manage
/// Extension and View Web Permissions. Both the bubble's "more options" button and a right click
/// on a toolbar icon show it; unlike Chrome, the bubble's menu offers Pin too, beside the row's
/// pin toggle.
struct ExtensionContextMenuModel: Equatable {
    /// Where the menu opened.
    enum Source: Equatable {
        case menuItem
        case toolbarAction
    }

    /// One row of the menu.
    enum Item: Equatable {
        /// The extension's name; opens its home page (the Chrome Web Store page of a store
        /// extension). Disabled when it has none.
        case name(String, enabled: Bool)
        /// "This Can Read and Change Site Data": Chromium's own menu with the site-access choices
        /// (the app has no site-access state of its own).
        case siteData
        case options
        /// "Remove from cmux" (Chrome: "Remove from Chrome").
        case remove
        /// "Installed by Your Administrator", disabled: a policy extension cannot be removed.
        case installedByAdmin
        /// Pin (true) or Unpin (false).
        case pin(Bool)
        case manageExtension
        case viewWebPermissions
        case separator

        /// The operation the row runs; nil for a separator or a disabled row.
        var operation: ExtensionMenuOperation? {
            switch self {
            case .name(_, let enabled): enabled ? .homePage : nil
            case .siteData: .siteAccess
            case .options: .options
            case .remove: .remove
            case .installedByAdmin, .separator: nil
            case .pin(let pin): pin ? .pin : .unpin
            case .manageExtension: .manageExtension
            case .viewWebPermissions: .webPermissions
            }
        }
    }

    let items: [Item]

    init(info: BrowserExtensionInfo, supportsManagement: Bool, source: Source) {
        var items: [Item] = [.name(info.name, enabled: info.location == .webstore), .separator]
        if info.isEnabled, info.hasAction {
            items += [.siteData, .separator]
        }
        if info.isEnabled, info.optionsURL != nil { items.append(.options) }
        if supportsManagement {
            if info.canRemove {
                items.append(.remove)
            } else if !info.mayModify {
                items.append(.installedByAdmin)
            }
        }
        if supportsManagement, info.isEnabled, info.hasAction {
            items.append(.pin(!info.isPinned))
        }
        items += [.separator, .manageExtension, .viewWebPermissions]
        self.items = Self.tidy(items)
    }

    /// Drops leading, trailing and doubled separators.
    private static func tidy(_ items: [Item]) -> [Item] {
        var result: [Item] = []
        for item in items {
            if item == .separator, result.isEmpty || result.last == .separator { continue }
            result.append(item)
        }
        if result.last == .separator { result.removeLast() }
        return result
    }

    /// The title of `item` (Chrome's Mac text).
    static func title(_ item: Item) -> String {
        switch item {
        case .name(let name, _): name
        case .siteData: Strings.extensionContextSiteData
        case .options: Strings.extensionMenuTitle(.options)
        case .remove: Strings.extensionContextRemove
        case .installedByAdmin: Strings.extensionContextInstalledByAdmin
        case .pin(let pin): pin ? Strings.extensionMenuPinTooltip : Strings.extensionMenuUnpinTooltip
        case .manageExtension: Strings.extensionContextManageExtension
        case .viewWebPermissions: Strings.extensionContextViewWebPermissions
        case .separator: ""
        }
    }

    /// The menu for extension `id`; each row runs its operation through `handler`. Row identifiers
    /// are `browser.extensions.menu.more.<id>.<operation>` (`debug.extensions.menu`, UI tests).
    func menu(extensionID id: String, title: String, handler: any ExtensionMenuHandling) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        menu.identifier = NSUserInterfaceItemIdentifier(ExtensionsMenu.moreIdentifier(id))
        for item in items {
            guard item != .separator else {
                menu.addItem(.separator())
                continue
            }
            let row = NSMenuItem(title: Self.title(item), action: nil, keyEquivalent: "")
            if let operation = item.operation {
                // The menu holds its handler while it is open (a wrapper may have no other owner).
                let target = ClosureMenuTarget { handler.perform(operation, extensionID: id) }
                row.target = target
                row.action = #selector(ClosureMenuTarget.run)
                row.representedObject = target
                row.identifier = NSUserInterfaceItemIdentifier("\(ExtensionsMenu.moreIdentifier(id)).\(operation.rawValue)")
            } else {
                row.isEnabled = false
            }
            menu.addItem(row)
        }
        return menu
    }
}
