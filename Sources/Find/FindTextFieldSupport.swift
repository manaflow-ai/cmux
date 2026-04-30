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

private let cmuxFindSelectionStore = NSMapTable<AnyObject, NSValue>.weakToStrongObjects()

func cmuxStoredFindSelection(for owner: AnyObject?) -> NSRange? {
    guard let owner else { return nil }
    return cmuxFindSelectionStore.object(forKey: owner)?.rangeValue
}

func cmuxStoreFindSelection(_ range: NSRange, for owner: AnyObject?) {
    guard let owner else { return }
    cmuxFindSelectionStore.setObject(NSValue(range: range), forKey: owner)
}

@discardableResult
func cmuxApplyFindFocusSelection(
    field: FindSelectionTrackingTextField,
    selectAll: Bool,
    alreadyFocused: Bool,
    rememberedRange: NSRange?
) -> NSRange? {
    guard let editor = field.currentEditor() as? NSTextView, !editor.hasMarkedText() else { return nil }
    if selectAll {
        let selection = field.cmuxRememberSelection(NSRange(location: 0, length: editor.string.utf16.count), in: editor.string)
        editor.setSelectedRange(selection)
        return selection
    }
    guard !alreadyFocused, let rememberedRange else { return nil }
    let selection = field.cmuxRememberSelection(rememberedRange, in: editor.string)
    editor.setSelectedRange(selection)
    return selection
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

func cmuxFindResponderSnapshot() -> [String: String] {
    let responder = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder
    var updates: [String: String] = [
        "firstResponderType": responder.map { String(describing: type(of: $0)) } ?? "",
        "firstResponderIdentifier": (responder as? NSView)?.identifier?.rawValue ?? "",
    ]
    if let textView = responder as? NSTextView {
        updates["firstResponderSelectedRange"] = NSStringFromRange(textView.selectedRange())
        if let owner = cmuxFieldEditorOwnerView(textView) {
            updates["fieldEditorOwnerType"] = String(describing: type(of: owner))
            updates["fieldEditorOwnerIdentifier"] = owner.identifier?.rawValue ?? ""
        }
    }
    return updates
}

class FindSelectionTrackingTextField: NSTextField {
    var cmuxLastSelectedRange: NSRange?
    var cmuxOnEscape: ((NSTextView) -> Bool)?
    private var cmuxSelectionObserver: NSObjectProtocol?
    private var cmuxKeyMonitor: Any?
    private weak var cmuxObservedEditor: NSTextView?

    deinit {
        cmuxDetachSelectionObserver()
        cmuxRemoveKeyMonitor()
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
        cmuxInstallKeyMonitorIfNeeded()
        _ = cmuxRememberSelectionFromCurrentEditor()
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        _ = cmuxRememberSelectionFromCurrentEditor()
    }

    override func textDidEndEditing(_ notification: Notification) {
        _ = cmuxRememberSelectionFromCurrentEditor()
        cmuxRemoveKeyMonitor()
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

    private func cmuxInstallKeyMonitorIfNeeded() {
        guard cmuxKeyMonitor == nil else { return }
        cmuxKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  let editor = self.currentEditor() as? NSTextView,
                  self.window?.firstResponder === editor else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
            guard flags.isEmpty, event.keyCode == 53, !editor.hasMarkedText(), self.cmuxOnEscape?(editor) == true else { return event }
            return nil
        }
    }

    private func cmuxRemoveKeyMonitor() {
        if let cmuxKeyMonitor {
            NSEvent.removeMonitor(cmuxKeyMonitor)
            self.cmuxKeyMonitor = nil
        }
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
