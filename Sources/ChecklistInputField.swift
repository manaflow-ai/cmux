import AppKit
import SwiftUI

/// A single-line AppKit text field for adding and editing checklist items
/// inside the checklist popover.
///
/// It exists because a SwiftUI `TextField` does not reliably become first
/// responder inside an `NSPopover` window while cmux's terminal is the focused
/// pane behind it: the terminal keeps AppKit first responder, so keystrokes
/// fall through to it. This field, like the sidebar rename field, calls
/// `window.makeFirstResponder(self)` the moment it enters its window, so it
/// wins first responder inside the popover window and typing lands here.
///
/// Behavior is checklist-specific (NOT rename): Return commits, Escape cancels,
/// and losing focus commits any non-empty text (so clicking a checkbox mid-type
/// keeps what you wrote). For editing, the caret is placed at the end rather
/// than selecting all. Inputs are value + closures only (snapshot-boundary).
struct ChecklistInputField: NSViewRepresentable {
    let initialText: String
    let placeholder: String
    let fontSize: CGFloat
    /// Return, or focus loss with non-empty text.
    let onCommit: (String) -> Void
    /// Escape.
    let onCancel: () -> Void
    /// Whether to place the caret at the end (edit) vs leave it empty (add).
    var selectsAllOnFocus: Bool = false
    /// Typed-text/caret color (so the field reads on a selected sidebar row).
    var textColor: NSColor = .labelColor

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> FocusGrabbingTextField {
        let field = FocusGrabbingTextField(string: initialText)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = textColor
        field.caretColor = textColor
        field.placeholderString = placeholder
        field.selectsAllOnFocus = selectsAllOnFocus
        field.setAccessibilityLabel(placeholder)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: FocusGrabbingTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
        nsView.font = .systemFont(ofSize: fontSize)
        nsView.textColor = textColor
        nsView.caretColor = textColor
        nsView.placeholderString = placeholder
    }

    /// Bridges Return/Escape and focus-loss to the commit / cancel closures.
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onCommit: (String) -> Void
        var onCancel: () -> Void
        private var committed = false

        init(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                committed = true
                onCommit(control.stringValue)
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                committed = true
                onCancel()
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard !committed else { return }
            committed = true
            let text = (obj.object as? NSTextField)?.stringValue ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onCancel()
            } else {
                onCommit(text)
            }
        }
    }
}

/// The `NSTextField` that grabs first responder on appear. The `selectsAllOnFocus`
/// flag chooses select-all (edit) vs caret-at-end (add) once the field editor exists.
final class FocusGrabbingTextField: NSTextField {
    var selectsAllOnFocus = false
    var caretColor: NSColor = .labelColor {
        didSet { (currentEditor() as? NSTextView)?.insertionPointColor = caretColor }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // The checklist popover is a separate NSPopover window floating over
        // the terminal's main window. Unless this popover window is key, the
        // main window stays key and its terminal keeps first responder, so
        // keystrokes fall through to the terminal. Make the popover window key
        // first, then take first responder inside it.
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(self)
        if selectsAllOnFocus {
            currentEditor()?.selectAll(nil)
        } else if let editor = currentEditor() {
            editor.selectedRange = NSRange(location: stringValue.count, length: 0)
        }
    }
}
