import AppKit

/// Sheets for Cloud prompts and results. Sheets are asynchronous (never
/// `runModal`), attached to the active window; with no window they fall
/// back to the result being logged only.
enum CloudPresenter {
    /// Shows a result; `copyable` text gets a Copy button.
    static func show(_ title: String, _ body: String, copyable: Bool = false, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: CloudStrings.ok)
        if copyable { alert.addButton(withTitle: CloudStrings.copy) }
        present(alert, in: window) { response in
            if response == .alertSecondButtonReturn { copy(body) }
        }
    }

    static func failure(_ error: any Error, in window: NSWindow?) {
        show(CloudStrings.failedTitle, String(describing: error), in: window)
    }

    /// Asks for a line of text. Calls `done` with the text, or nil on cancel.
    static func askText(_ title: String, initial: String, button: String, in window: NSWindow?, done: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: CloudStrings.cancel)
        alert.window.initialFirstResponder = field
        present(alert, in: window) { done($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    /// Asks to pick one of `choices` (title, value).
    static func choose(_ title: String, _ choices: [(String, String)], selected: String?, in window: NSWindow?, done: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        for (label, value) in choices {
            popup.addItem(withTitle: label)
            popup.lastItem?.representedObject = value
            if value == selected { popup.select(popup.lastItem) }
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: CloudStrings.select)
        alert.addButton(withTitle: CloudStrings.cancel)
        present(alert, in: window) { done($0 == .alertFirstButtonReturn ? popup.selectedItem?.representedObject as? String : nil) }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func present(_ alert: NSAlert, in window: NSWindow?, done: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window else { return done(.cancel) }
        alert.beginSheetModal(for: window, completionHandler: done)
    }
}
