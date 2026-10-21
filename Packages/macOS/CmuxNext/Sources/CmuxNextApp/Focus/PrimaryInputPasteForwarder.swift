import AppKit

/// The target ``PrimaryInputPasteRoute`` gives a paste command: the primary
/// input takes the keyboard, then runs the command itself, so its own paste
/// rules apply (Home's box takes files and pictures through its intake).
/// Validation asks the input, so Edit > Paste is enabled exactly when the
/// input would take the pasteboard.
@MainActor
final class PrimaryInputPasteForwarder: NSObject, NSMenuItemValidation {
    private weak var input: NSView?

    init(input: NSView) {
        self.input = input
    }

    @objc func paste(_ sender: Any?) { forward(#selector(NSText.paste(_:)), sender) }
    @objc func pasteAsPlainText(_ sender: Any?) { forward(#selector(NSTextView.pasteAsPlainText(_:)), sender) }
    @objc func pasteAsRichText(_ sender: Any?) { forward(#selector(NSTextView.pasteAsRichText(_:)), sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let input, let action = item.action, input.responds(to: action) else { return false }
        if let validator = input as? any NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }
        return true
    }

    private func forward(_ action: Selector, _ sender: Any?) {
        guard let input, let window = input.window else { return }
        if window.firstResponder !== input { guard window.makeFirstResponder(input) else { return } }
        _ = input.tryToPerform(action, with: sender)
    }
}
