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
    private var pendingFocusRequestGeneration: UInt64 = 0
    private var pendingFocusAlreadyFocused = false
    private var pendingFocusSelectAll = false
    private var pendingFocusRememberedRange: NSRange?

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
        let rememberedRange = field.cmuxLastSelectedRange
            ?? cmuxStoredFindSelection(for: parent.selectionOwner)
            ?? lastSelectedRange

        stageFocusSelection(
            generation: generation,
            selectAll: parent.selectAllOnFocusRequest,
            alreadyFocused: alreadyFocused,
            rememberedRange: rememberedRange
        )
        guard alreadyFocused || window.makeFirstResponder(field) else {
            clearPendingFocusSelection()
            return
        }
        lastAppliedFocusRequestGeneration = generation
        lastAppliedFocusRequestOwner = parent.selectionOwner
        applyPendingFocusSelection(to: field)
        parent.onFieldDidFocus()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !isProgrammaticMutation,
              let field = notification.object as? NSTextField else { return }
        parent.text = field.stringValue
        rememberSelection(from: field)
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        if let field = notification.object as? WebViewFindNativeTextField {
            applyPendingFocusSelection(to: field)
        }
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
            return false
        }
    }

    func handleEscape(from textView: NSTextView) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        rememberSelection(from: textView)
        parent.onEscape()
        return true
    }

    private func stageFocusSelection(
        generation: UInt64,
        selectAll: Bool,
        alreadyFocused: Bool,
        rememberedRange: NSRange?
    ) {
        pendingFocusRequestGeneration = generation
        pendingFocusSelectAll = selectAll
        pendingFocusAlreadyFocused = alreadyFocused
        pendingFocusRememberedRange = rememberedRange
    }

    private func applyPendingFocusSelection(to field: WebViewFindNativeTextField) {
        let generation = pendingFocusRequestGeneration
        guard generation != 0 else { return }
        guard parent.focusRequestGeneration == generation,
              parent.canApplyFocusRequest(generation) else {
            clearPendingFocusSelection()
            return
        }
        guard let editor = field.currentEditor() as? NSTextView else { return }
        defer { clearPendingFocusSelection() }
        guard !editor.hasMarkedText() else { return }
        if let selection = cmuxApplyFindFocusSelection(
            field: field,
            selectAll: pendingFocusSelectAll,
            alreadyFocused: pendingFocusAlreadyFocused,
            rememberedRange: pendingFocusRememberedRange
        ) {
            lastSelectedRange = selection
        }
    }

    private func clearPendingFocusSelection() {
        pendingFocusRequestGeneration = 0
        pendingFocusSelectAll = false
        pendingFocusAlreadyFocused = false
        pendingFocusRememberedRange = nil
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
