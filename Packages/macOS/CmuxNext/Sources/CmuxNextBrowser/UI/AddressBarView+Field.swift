public import AppKit

// The field editor, text field delegate and suggestion card surfaces of
// `AddressBarView`: each turns an AppKit callback into one `OmnibarInput`.
extension AddressBarView: OmnibarPopupSurface {
    func showRows(_ rows: [BrowserSuggestion], highlighted: Int?) {
        guard let window else { return }
        // The card is clipped to the browser pane (the chrome view), else to the window.
        let pane = sequence(first: superview, next: { $0?.superview }).lazy.compactMap { $0 as? BrowserChromeView }.first
        panel.show(rows, highlighted: highlighted, below: self, pane: pane ?? window.contentView ?? self, in: window)
    }

    func highlightRow(_ row: Int?) { panel.highlight(row) }

    func dismissRows() { panel.dismiss() }
}

extension AddressBarView: OmnibarFieldEditorSink {
    func fieldEditorDidChange(kind: OmnibarState.EditKind?) { observeField(kind: kind) }

    func fieldEditorKey(_ key: OmnibarInput.Key) -> Bool { controller.send(.key(key)) }

    func fieldEditorMouseDown(clickCount: Int, button: OmnibarInput.MouseButton, word: NSRange?) {
        controller.send(.fieldMouseDown(clickCount: clickCount, button: button, word: word))
    }

    func fieldEditorMouseUp() { controller.send(.fieldMouseUp) }

    var copyContent: OmnibarCopy? { OmnibarReducer.copyContent(of: controller.state, resolver: resolver) }

    var canUndo: Bool { controller.state.hasFocus && !controller.state.undo.isEmpty }
    var canRedo: Bool { controller.state.hasFocus && !controller.state.redo.isEmpty }
}

extension AddressBarView: NSTextFieldDelegate {
    public func controlTextDidChange(_ notification: Notification) {
        observeField(kind: field.editor?.lastEditKind ?? .insert)
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        controller.send(.focusLost)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): controller.send(.key(.down))
        case #selector(NSResponder.moveUp(_:)): controller.send(.key(.up))
        case #selector(NSResponder.insertTab(_:)): controller.send(.key(.tab))
        case #selector(NSResponder.insertBacktab(_:)): controller.send(.key(.backTab))
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            controller.send(.key(.enter(.init(NSApp.currentEvent?.modifierFlags ?? []))))
        case #selector(NSResponder.cancelOperation(_:)): controller.send(.key(.escape))
        case #selector(NSResponder.selectAll(_:)): controller.send(.key(.selectAll))
        // The Home key (Shift-Home extends); Cmd-Left is a caret move.
        case #selector(NSResponder.scrollToBeginningOfDocument(_:)): controller.send(.key(.home(extend: false)))
        case #selector(NSResponder.moveToBeginningOfDocumentAndModifySelection(_:)): controller.send(.key(.home(extend: true)))
        // Backspace at the start leaves an extension keyword session.
        case #selector(NSResponder.deleteBackward(_:)): controller.send(.key(.backspaceAtStart))
        default: false
        }
    }
}
