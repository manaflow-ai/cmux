import AppKit

extension NativePopupContent {
    func navigateFromSlider(_ id: String, key: UInt16) -> Bool {
        let enabled = enabledRows
        guard let index = enabled.firstIndex(where: { $0.0.id == id }),
              let following = enabled.dropFirst(index + 1).first(where: { $0.0.kind == .action }) else { return false }
        if key == 125 {
            selected = following.0.id; selectionReason = "keyboard"
            paintSelection()
            window?.makeFirstResponder(self)
            emit(.highlight, selected, nil)
        }
        return true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): return handleKey(125)
        case #selector(NSResponder.moveUp(_:)): return handleKey(126)
        case #selector(NSResponder.insertTab(_:)):
            guard control === search, let search, search.isEnabled,
                  model?.search?.completeOnTab == true else { return false }
            guard let row = enabledRows.first(where: { $0.0.id == selected && $0.0.kind == .action && $0.0.completion != nil })
                    ?? enabledRows.first(where: { $0.0.kind == .action && $0.0.completion != nil }),
                  let completion = row.0.completion, completion != search.stringValue else { return false }
            emit(.complete, row.0.id, completion)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            guard control === search, let search, search.isEnabled else { return false }
            if model?.search?.submitOnReturn == true {
                let id = enabledRows.first(where: { $0.0.id == selected })?.0.id
                emit(.submit, id, search.stringValue)
                return true
            }
            return handleKey(36)
        case #selector(NSResponder.cancelOperation(_:)): return handleKey(53)
        default: return false
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field.isEnabled,
              let id = fields.first(where: { $0.value === field })?.key else { return }
        if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        let value = field.stringValue
        inputState.record(id: id, value: value, model: model)
        let isSearch = field === search
        if isSearch, model?.search?.autoHighlight != nil {
            searchHasInput = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            selected = nil; selectionReason = "none"
            paintSelection()
        }
        if var pending = pendingCompositionModel {
            pendingCompositionModel = nil
            if isSearch {
                if pending.search?.id == id { pending.search?.value = value }
            } else {
                // The deferred descriptor predates the IME commit. Carry the committed
                // value into the matching field before rebuilding any native controls.
                let preserveCommit: (NativePopupRow) -> NativePopupRow = { row in
                    var row = row
                    if row.id == id, row.kind == .textField { row.value = value }
                    return row
                }
                pending.rows = pending.rows.map(preserveCommit)
                pending.rail = pending.rail?.map(preserveCommit)
                pending.footer = pending.footer?.map(preserveCommit)
            }
            update(pending)
        }
        emit(isSearch ? .search : .change, id, value)
    }
}
