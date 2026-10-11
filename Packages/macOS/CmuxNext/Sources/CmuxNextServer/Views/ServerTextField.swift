import AppKit
import CmuxNextDesign
import SwiftUI

/// A borderless themed text field (no focus ring, caret and selection in
/// theme colors) over a SwiftUI card.
struct ServerTextField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let monospaced: Bool
    let size: CGFloat
    let onChange: (String) -> Void

    func makeNSView(context: Context) -> ThemedTextField {
        let field = ThemedTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.fill = { .clear }
        field.font = monospaced ? .monospacedSystemFont(ofSize: size, weight: .medium) : .systemFont(ofSize: size)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        return field
    }

    func updateNSView(_ field: ThemedTextField, context: Context) {
        context.coordinator.onChange = onChange
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onChange: (String) -> Void

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            onChange(field.stringValue)
        }
    }
}
