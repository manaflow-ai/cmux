import AppKit

enum FindFocusNotificationKey {
    static let selectAll = "cmux.find.selectAll"
}

func cmuxClampedFindSelection(_ range: NSRange, in text: String) -> NSRange {
    let textLength = text.utf16.count
    guard range.location != NSNotFound else {
        return NSRange(location: textLength, length: 0)
    }
    let location = min(max(range.location, 0), textLength)
    let length = min(max(range.length, 0), textLength - location)
    return NSRange(location: location, length: length)
}

func cmuxTextFieldIsFirstResponder(_ field: NSTextField, in window: NSWindow) -> Bool {
    let firstResponder = window.firstResponder
    if firstResponder === field { return true }
    if let editor = field.currentEditor() as? NSTextView, firstResponder === editor { return true }
    return (firstResponder as? NSTextView).flatMap { cmuxFieldEditorOwnerView($0) } === field
}

private let cmuxFindSelectionChangingCommands: Set<String> = [
    "moveLeft:",
    "moveRight:",
    "moveBackward:",
    "moveForward:",
    "moveUp:",
    "moveDown:",
    "moveWordLeft:",
    "moveWordRight:",
    "moveWordBackward:",
    "moveWordForward:",
    "moveToBeginningOfLine:",
    "moveToEndOfLine:",
    "moveToBeginningOfDocument:",
    "moveToEndOfDocument:",
    "moveLeftAndModifySelection:",
    "moveRightAndModifySelection:",
    "moveBackwardAndModifySelection:",
    "moveForwardAndModifySelection:",
    "moveUpAndModifySelection:",
    "moveDownAndModifySelection:",
    "moveWordLeftAndModifySelection:",
    "moveWordRightAndModifySelection:",
    "moveWordBackwardAndModifySelection:",
    "moveWordForwardAndModifySelection:",
    "moveToBeginningOfLineAndModifySelection:",
    "moveToEndOfLineAndModifySelection:",
    "moveToBeginningOfDocumentAndModifySelection:",
    "moveToEndOfDocumentAndModifySelection:",
    "selectAll:",
]

func cmuxFindCommandMayChangeSelection(_ selector: Selector) -> Bool {
    cmuxFindSelectionChangingCommands.contains(NSStringFromSelector(selector))
}

@discardableResult
func cmuxRememberFindSelection(in root: NSView?) -> NSRange? {
    guard let root else { return nil }
    if let field = root as? FindSelectionTrackingTextField,
       let selection = field.cmuxRememberSelectionFromCurrentEditor() {
        return selection
    }
    for subview in root.subviews {
        if let selection = cmuxRememberFindSelection(in: subview) {
            return selection
        }
    }
    return nil
}

class FindSelectionTrackingTextField: NSTextField {
    var cmuxLastSelectedRange: NSRange?
    private var cmuxSelectionObserver: NSObjectProtocol?
    private weak var cmuxObservedEditor: NSTextView?

    deinit {
        cmuxDetachSelectionObserver()
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        cmuxAttachSelectionObserverIfNeeded()
        cmuxRestoreRememberedSelection()
        return true
    }

    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        cmuxAttachSelectionObserverIfNeeded()
        _ = cmuxRememberSelectionFromCurrentEditor()
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        _ = cmuxRememberSelectionFromCurrentEditor()
    }

    override func textDidEndEditing(_ notification: Notification) {
        _ = cmuxRememberSelectionFromCurrentEditor()
        cmuxDetachSelectionObserver()
        super.textDidEndEditing(notification)
    }

    func cmuxRememberSelection(_ range: NSRange, in text: String) -> NSRange {
        let selection = cmuxClampedFindSelection(range, in: text)
        cmuxLastSelectedRange = selection
        return selection
    }

    func cmuxRememberSelection(from textView: NSTextView) -> NSRange {
        cmuxRememberSelection(textView.selectedRange(), in: textView.string)
    }

    func cmuxRememberSelectionFromCurrentEditor() -> NSRange? {
        guard let editor = currentEditor() as? NSTextView else { return nil }
        return cmuxRememberSelection(from: editor)
    }

    private func cmuxAttachSelectionObserverIfNeeded() {
        guard let editor = currentEditor() as? NSTextView else { return }
        if let cmuxObservedEditor, cmuxObservedEditor !== editor {
            cmuxDetachSelectionObserver()
        }
        guard cmuxSelectionObserver == nil else { return }
        cmuxObservedEditor = editor
        cmuxSelectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: editor,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let textView = notification.object as? NSTextView else { return }
            _ = self.cmuxRememberSelection(from: textView)
        }
    }

    private func cmuxDetachSelectionObserver() {
        if let cmuxSelectionObserver {
            NotificationCenter.default.removeObserver(cmuxSelectionObserver)
            self.cmuxSelectionObserver = nil
        }
        cmuxObservedEditor = nil
    }

    private func cmuxRestoreRememberedSelection() {
        guard let cmuxLastSelectedRange else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let editor = self.currentEditor() as? NSTextView,
                  !editor.hasMarkedText() else { return }
            let selection = self.cmuxRememberSelection(cmuxLastSelectedRange, in: editor.string)
            editor.setSelectedRange(selection)
        }
    }
}
