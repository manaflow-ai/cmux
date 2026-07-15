import AppKit

/// NSTextField delegate and focus-lease owner for ``WebViewFindTextField``.
@MainActor
final class WebViewFindTextFieldCoordinator: NSObject, NSTextFieldDelegate {
    var parent: WebViewFindTextField
    var isProgrammaticMutation = false
    var lastAppliedFocusRequestGeneration: UInt64 = 0
    weak var lastAppliedFocusRequestOwner: AnyObject?
    var lastSelectedRange: NSRange?
    weak var parentField: WebViewFindNativeTextField?

    init(parent: WebViewFindTextField) {
        self.parent = parent
    }

    func applyFocusRequest(to field: WebViewFindNativeTextField) {
        let generation = parent.focusRequestGeneration
        guard generation != 0,
              generation != lastAppliedFocusRequestGeneration ||
                lastAppliedFocusRequestOwner !== parent.selectionOwner,
              parent.canApplyFocusRequest(generation),
              let window = field.window else { return }

        let alreadyFocused = cmuxTextFieldIsFirstResponder(field, in: window)
        guard alreadyFocused || window.makeFirstResponder(field) else { return }
        lastAppliedFocusRequestGeneration = generation
        lastAppliedFocusRequestOwner = parent.selectionOwner
        let rememberedRange = field.cmuxLastSelectedRange
            ?? cmuxStoredFindSelection(for: parent.selectionOwner)
            ?? lastSelectedRange
        if let selection = cmuxApplyFindFocusSelection(
            field: field,
            selectAll: parent.selectAllOnFocusRequest,
            alreadyFocused: alreadyFocused,
            rememberedRange: rememberedRange
        ) {
            lastSelectedRange = selection
        } else {
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field,
                      self.parent.focusRequestGeneration == generation,
                      self.parent.canApplyFocusRequest(generation),
                      let selection = cmuxApplyFindFocusSelection(
                          field: field,
                          selectAll: self.parent.selectAllOnFocusRequest,
                          alreadyFocused: alreadyFocused,
                          rememberedRange: rememberedRange
                      ) else { return }
                self.lastSelectedRange = selection
            }
        }
        parent.onFieldDidFocus()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !isProgrammaticMutation,
              let field = notification.object as? NSTextField else { return }
        parent.text = field.stringValue
        rememberSelection(from: field)
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        parent.onFieldDidFocus()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        rememberSelection(from: field)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            return handleEscape(from: textView)
        case #selector(NSResponder.insertNewline(_:)):
            guard !textView.hasMarkedText() else { return false }
            rememberSelection(from: textView)
            let isShift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            parent.onReturn(isShift)
            return true
        default:
            if cmuxFindCommandMayChangeSelection(commandSelector) {
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let textView else { return }
                    self?.rememberSelection(from: textView)
                }
            }
            return false
        }
    }

    func handleEscape(from textView: NSTextView) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        rememberSelection(from: textView)
        parent.onEscape()
        return true
    }

    private func rememberSelection(from field: NSTextField) {
        if let field = field as? WebViewFindNativeTextField,
           let selection = field.cmuxRememberSelectionFromCurrentEditor() {
            lastSelectedRange = selection
            return
        }
        guard let editor = field.currentEditor() as? NSTextView else { return }
        rememberSelection(from: editor)
    }

    private func rememberSelection(from textView: NSTextView) {
        let selection = cmuxClampedFindSelection(textView.selectedRange(), in: textView.string)
        lastSelectedRange = selection
        parentField?.cmuxLastSelectedRange = selection
        cmuxStoreFindSelection(selection, for: parent.selectionOwner)
    }
}
