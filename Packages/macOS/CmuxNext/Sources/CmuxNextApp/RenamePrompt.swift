import AppKit

/// Sheet with one text field, for renames that have no inline editor.
enum RenamePrompt {
    static func run(title: String, initial: String, in window: NSWindow, completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: Strings.renameConfirm)
        alert.addButton(withTitle: Strings.cancel)
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            completion(name)
        }
    }
}
