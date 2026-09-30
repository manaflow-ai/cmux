public import AppKit

/// Chooses Extensions menu items by what they do, as a click would
/// (`debug.extensions.menu`, UI tests). Row controls run through the row
/// view; other items through the menu.
public enum ExtensionMenuDriver {
    /// `operation` is a row control (`run`, `pin`, `unpin`, `more`) of
    /// `extension`'s row, or an `ExtensionMenuOperation` raw value of a
    /// footer or extension menu item. Returns false when no item matches.
    public static func choose(_ operation: String, extension id: String?, in menu: NSMenu) -> Bool {
        if let id, let row = menu.items.lazy.compactMap({ $0.view as? ExtensionMenuRowView }).first(where: { $0.extensionID == id }) {
            switch operation {
            case "run": row.run(); return true
            case "more": row.more(); return true
            case "pin", "unpin":
                guard (operation == "pin") != row.isPinned else { return true }
                row.pin()
                return true
            default: break
            }
        }
        var identifiers: [String] = []
        if let footer = ExtensionMenuOperation(rawValue: operation) { identifiers.append(ExtensionsMenu.Identifier.footer(footer)) }
        if let id { identifiers.append("\(ExtensionsMenu.Identifier.more(id)).\(operation)") }
        guard let index = menu.items.firstIndex(where: { identifiers.contains($0.identifier?.rawValue ?? "") }) else {
            return false
        }
        menu.cancelTracking()
        menu.performActionForItem(at: index)
        return true
    }
}
