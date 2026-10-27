import AppKit

// Reports (`debug.extensions.menu`, UI tests): what the bubble or its context menu shows, and choosing an item as a
// click would.
extension ExtensionsMenuController {
    /// The open context menu's items, else the bubble's rows and footer; nil when closed.
    var report: [ReportItem]? {
        if let menu = presentedContextMenu {
            return menu.items.map { item in
                item.isSeparatorItem ? ReportItem(title: "-", isEnabled: false, isSeparator: true)
                    : ReportItem(title: item.title, identifier: item.identifier?.rawValue, isEnabled: item.isEnabled)
            }
        }
        guard isShown else { return nil }
        var items = content.rows.map { row in
            ReportItem(title: row.info.name, identifier: ExtensionsMenu.rowIdentifier(row.extensionID),
                       extensionID: row.extensionID, isEnabled: row.primary.isEnabled)
        }
        items.append(ReportItem(title: "-", isEnabled: false, isSeparator: true))
        items.append(ReportItem(title: Strings.extensionMenuTitle(.manage), identifier: ExtensionsMenu.footerIdentifier(.manage),
                                isEnabled: true))
        items.append(ReportItem(title: Strings.extensionMenuGetExtensions, identifier: ExtensionsMenu.footerIdentifier(.webStore),
                                isEnabled: true))
        return items
    }

    /// Chooses an item as a click would: a row control (`run`, `sidePanel`, `pin`, `unpin`,
    /// `more`) of extension `id`, `manage`, `webStore`, `close`, or an operation of the open context
    /// menu. False when no item matches.
    func choose(_ operation: String, extension id: String?) -> Bool {
        if let menu = presentedContextMenu, let id,
           let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == "\(ExtensionsMenu.moreIdentifier(id)).\(operation)" }) {
            menu.cancelTracking()
            menu.performActionForItem(at: index)
            return true
        }
        guard isShown else { return false }
        if let id, let row = content.row(for: id) {
            switch operation {
            case "run": row.primary.onPress?(); return true
            case "more": row.moreButton.onPress?(); return true
            case "sidePanel" where row.hasSidePanel: row.sidePanelButton.onPress?(); return true
            case "pin", "unpin":
                if (operation == "pin") != row.isPinned { row.togglePin() }
                return true
            default: break
            }
        }
        switch operation {
        case "manage": content.manageButton.onPress?(); return true
        case "webStore": content.webStoreButton.onPress?(); return true
        case "close": close(); return true
        default: return false
        }
    }

    /// Closes the open context menu, else the bubble.
    func dismiss() {
        if let menu = presentedContextMenu { menu.cancelTracking() } else { close() }
    }
}
