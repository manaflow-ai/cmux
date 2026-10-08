#if canImport(UIKit)
import UIKit

/// Hidden documentless input proxy that forwards committed keyboard output.
@MainActor
final class BrowserStreamInputView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onKey: ((String) -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var keyboardType: UIKeyboardType { get { .default } set {} }
    var returnKeyType: UIReturnKeyType { get { .go } set {} }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }

    override var isAccessibilityElement: Bool {
        get { false }
        set {}
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            command(UIKeyCommand.inputUpArrow, action: #selector(up)),
            command(UIKeyCommand.inputDownArrow, action: #selector(down)),
            command(UIKeyCommand.inputLeftArrow, action: #selector(left)),
            command(UIKeyCommand.inputRightArrow, action: #selector(right)),
            command("\t", action: #selector(tab)),
            command(UIKeyCommand.inputEscape, action: #selector(escape)),
        ]
    }

    func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        let components = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, component) in components.enumerated() {
            if !component.isEmpty { onText?(String(component)) }
            if index < components.count - 1 { onKey?("return") }
        }
    }

    func deleteBackward() {
        onKey?("delete")
    }

    private func command(_ input: String, action: Selector) -> UIKeyCommand {
        UIKeyCommand(input: input, modifierFlags: [], action: action)
    }

    @objc private func up() { onKey?("up") }
    @objc private func down() { onKey?("down") }
    @objc private func left() { onKey?("left") }
    @objc private func right() { onKey?("right") }
    @objc private func tab() { onKey?("tab") }
    @objc private func escape() { onKey?("escape") }
}
#endif
