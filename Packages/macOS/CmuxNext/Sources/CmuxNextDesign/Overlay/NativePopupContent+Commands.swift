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
}
