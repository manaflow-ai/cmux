import AppKit
import SwiftUI

/// Native text-field bridge shared by find bars hosted over WKWebView panels.
struct WebViewFindTextField: NSViewRepresentable {
    @Binding var text: String
    let accessibilityIdentifier: String
    let focusRequestGeneration: UInt64
    let selectAllOnFocusRequest: Bool
    let selectionOwner: AnyObject
    let canApplyFocusRequest: (UInt64) -> Bool
    let onFieldDidFocus: () -> Void
    let onEscape: () -> Void
    let onReturn: (_ isShift: Bool) -> Void
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontPercent

    func makeCoordinator() -> WebViewFindTextFieldCoordinator {
        WebViewFindTextFieldCoordinator(parent: self)
    }

    func makeNSView(context: Context) -> WebViewFindNativeTextField {
        let field = WebViewFindNativeTextField(frame: .zero)
        configure(field, coordinator: context.coordinator)
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: WebViewFindNativeTextField, context: Context) {
        context.coordinator.parent = self
        configure(field, coordinator: context.coordinator)

        if let editor = field.currentEditor() as? NSTextView {
            if editor.string != text, !editor.hasMarkedText() {
                let selectedRange = field.cmuxRememberSelection(editor.selectedRange(), in: text)
                context.coordinator.isProgrammaticMutation = true
                editor.string = text
                field.stringValue = text
                editor.setSelectedRange(selectedRange)
                context.coordinator.lastSelectedRange = selectedRange
                cmuxStoreFindSelection(selectedRange, for: selectionOwner)
                context.coordinator.isProgrammaticMutation = false
            }
        } else if field.stringValue != text {
            field.stringValue = text
        }

        context.coordinator.applyFocusRequest(to: field)
    }

    static func dismantleNSView(
        _ field: WebViewFindNativeTextField,
        coordinator: WebViewFindTextFieldCoordinator
    ) {
        field.delegate = nil
        field.cmuxSelectionOwner = nil
        field.cmuxOnEscape = nil
        field.onMovedToWindow = nil
        coordinator.parentField = nil
    }

    private func configure(
        _ field: WebViewFindNativeTextField,
        coordinator: WebViewFindTextFieldCoordinator
    ) {
        field.font = GlobalFontMagnification.systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = String(localized: "search.placeholder", defaultValue: "Search")
        field.setAccessibilityIdentifier(accessibilityIdentifier)
        field.delegate = coordinator
        field.cmuxSelectionOwner = selectionOwner
        field.cmuxOnEscape = { [weak coordinator] textView in
            coordinator?.handleEscape(from: textView) ?? false
        }
        field.onMovedToWindow = { [weak field, weak coordinator] in
            guard let field else { return }
            coordinator?.applyFocusRequest(to: field)
        }
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        coordinator.parentField = field
    }
}
