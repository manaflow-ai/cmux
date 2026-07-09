import AppKit
import SwiftUI

/// AppKit-backed text field for ``NoteTitleRenameField``: keeps the SwiftUI
/// draft binding in sync, mirrors first-responder state into `isFocused`, and
/// maps Enter/Escape to commit/cancel through the injected closures.
struct NoteTitleTextFieldRepresentable: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var isFocused: Bool
    let font: NSFont
    let foregroundColor: NSColor
    /// Focus the field (title selected) as soon as it lands in a window —
    /// used by the rename swap, where the field only exists while editing.
    var focusOnAttach: Bool = false
    let onBeginEditing: () -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void

    /// Delegate bridge; see ``NoteTitleTextFieldCoordinator``.
    typealias Coordinator = NoteTitleTextFieldCoordinator

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NoteTitleNativeTextField {
        let field = NoteTitleNativeTextField(frame: .zero)
        field.delegate = context.coordinator
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.onBeginEditingClick = onBeginEditing
        field.beginsEditingOnAttach = focusOnAttach
        applyStyle(to: field)
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NoteTitleNativeTextField, context: Context) {
        context.coordinator.parent = self
        field.onBeginEditingClick = onBeginEditing
        applyStyle(to: field)
        if field.currentEditor() == nil, field.stringValue != text {
            context.coordinator.isProgrammaticMutation = true
            field.stringValue = text
            context.coordinator.isProgrammaticMutation = false
        }
    }

    static func dismantleNSView(_ field: NoteTitleNativeTextField, coordinator: Coordinator) {
        field.delegate = nil
    }

    private func applyStyle(to field: NoteTitleNativeTextField) {
        field.font = font
        field.textColor = foregroundColor.withAlphaComponent(0.88)
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: font,
                .foregroundColor: foregroundColor.withAlphaComponent(0.42)
            ]
        )
    }
}
