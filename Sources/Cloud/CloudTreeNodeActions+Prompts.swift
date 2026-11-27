import AppKit
import Foundation

/// The modal prompts the Cloud tree's destructive and rename verbs run before
/// their mutation: the house confirm shape and a one-field rename sheet.
extension CloudTreeNodeActions {
    /// The house destructive-confirm shape (`NSAlert`, warning style, verb first).
    @MainActor
    static func confirmDestructive(title: String, message: String, verb: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: verb)
        alert.addButton(withTitle: String(localized: "cloudTree.confirm.cancel", defaultValue: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// A one-field rename prompt. A terminal may explicitly clear its custom
    /// name; a workspace must keep a non-empty name because it is also its
    /// stable local identity label.
    @MainActor
    static func promptForName(title: String, current: String, allowsClear: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "cloudTree.rename.confirm", defaultValue: "Rename"))
        if allowsClear {
            alert.addButton(withTitle: String(localized: "cloudTree.rename.clear", defaultValue: "Clear"))
        }
        alert.addButton(withTitle: String(localized: "cloudTree.confirm.cancel", defaultValue: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        if allowsClear && response == .alertSecondButtonReturn {
            return ""
        }
        guard response == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
