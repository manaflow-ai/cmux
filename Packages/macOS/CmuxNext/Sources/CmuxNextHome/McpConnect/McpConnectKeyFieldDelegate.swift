import AppKit

/// The private key field's delegate: keeps the typed key in the card's state, turns Save on while
/// there is a key, and sends the key on Return.
@MainActor
final class McpConnectKeyFieldDelegate: NSObject, NSTextFieldDelegate {
    private let state: McpConnectCardState
    private weak var save: NSView?
    private let submit: @MainActor () -> Void

    init(state: McpConnectCardState, save: NSView, submit: @escaping @MainActor () -> Void) {
        self.state = state
        self.save = save
        self.submit = submit
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        state.key = field.stringValue
        (save as? NSControl)?.isEnabled = !state.key.isEmpty
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        submit()
        return true
    }
}
