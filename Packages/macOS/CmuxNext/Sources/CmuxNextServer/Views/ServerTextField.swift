import AppKit
import CmuxNextDesign
import SwiftUI

/// A borderless themed text field (no focus ring, caret and selection in
/// theme colors) over a SwiftUI card. With `autofocus` it takes its window's
/// first responder as it joins the window (the Add Server code field); in a
/// panel that is not key that moves no keys away from the user's window.
struct ServerTextField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let monospaced: Bool
    let size: CGFloat
    var alignment: NSTextAlignment = .natural
    var autofocus = false
    let onChange: (String) -> Void

    func makeNSView(context: Context) -> ServerTextFieldBox {
        let field = ThemedTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.fill = { .clear }
        field.font = Typography.system(monospaced ? .monospaced : .default, size: size,
                                       weight: monospaced ? TypeScale.emphasis : TypeScale.regular)
        field.alignment = alignment
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        return ServerTextFieldBox(field: field, autofocus: autofocus)
    }

    func updateNSView(_ box: ServerTextFieldBox, context: Context) {
        context.coordinator.onChange = onChange
        if box.field.stringValue != text { box.field.stringValue = text }
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
