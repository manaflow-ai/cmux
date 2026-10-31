import AppKit
import SwiftUI

/// Native single-line text field for the tab search, so ↑/↓/Return/Esc reach
/// the dropdown selection handlers instead of the field editor. Mirrors the
/// command palette's native-field approach.
///
/// Focus is driven by `focusToken`: each increment focuses the field once, so
/// the field never steals focus on an ordinary re-render and there is no
/// sustained focus state written back during a view update.
struct SidebarTabSearchTextField: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int
    let placeholder: String
    let onSubmit: () -> Void
    let onEscape: () -> Void
    let onMoveSelection: (Int) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = PlainTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.stringValue = text
        field.font = .systemFont(ofSize: 12)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        context.coordinator.lastFocusToken = focusToken
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        if placeholder != field.placeholderString {
            field.placeholderString = placeholder
        }
        // Focus exactly once per new token (the shortcut increments it). AppKit
        // focus manipulation from an AppKit bridge view is allowed; no SwiftUI
        // state is written here.
        if focusToken != context.coordinator.lastFocusToken {
            context.coordinator.lastFocusToken = focusToken
            field.window?.makeFirstResponder(field)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SidebarTabSearchTextField
        var lastFocusToken: Int = 0

        init(_ parent: SidebarTabSearchTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveSelection(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveSelection(-1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                guard !textView.hasMarkedText() else { return false }
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                guard !textView.hasMarkedText() else { return false }
                // `onEscape` restores terminal focus, which resigns the field.
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }

    /// Borderless, transparent single-line field so it blends into the search
    /// pill drawn by SwiftUI.
    final class PlainTextField: NSTextField {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            isBordered = false
            isBezeled = false
            drawsBackground = false
            focusRingType = .none
            usesSingleLineMode = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
