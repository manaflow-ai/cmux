import AppKit
import SwiftUI

/// `NSTextFieldDelegate` for ``NoteTitleTextFieldRepresentable``: forwards
/// edits and focus changes into the SwiftUI bindings, and maps Enter/Escape
/// to the representable's commit/cancel closures.
@MainActor
final class NoteTitleTextFieldCoordinator: NSObject, NSTextFieldDelegate {
    var parent: NoteTitleTextFieldRepresentable
    var isProgrammaticMutation = false
    var skipCommitOnEndEditing = false

    init(parent: NoteTitleTextFieldRepresentable) {
        self.parent = parent
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !isProgrammaticMutation else { return }
        guard let field = obj.object as? NSTextField else { return }
        parent.text = field.stringValue
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        if !parent.isFocused {
            parent.isFocused = true
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if parent.isFocused {
            parent.isFocused = false
        }
        if skipCommitOnEndEditing {
            skipCommitOnEndEditing = false
            return
        }
        parent.onCommit()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            textView.window?.makeFirstResponder(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            skipCommitOnEndEditing = true
            parent.onCancel()
            textView.window?.makeFirstResponder(nil)
            return true
        default:
            return false
        }
    }
}
