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

func cmuxFindEventIsPlainEscape(_ event: NSEvent) -> Bool {
    ShortcutStroke.normalizedModifierFlags(from: event.modifierFlags).isEmpty && ShortcutStroke.isEscapeCancelEvent(event)
}

private let cmuxFindSelectionStore = NSMapTable<AnyObject, NSValue>.weakToStrongObjects()
private let cmuxFindFieldEditorOwners = NSMapTable<NSTextView, FindSelectionTrackingTextField>.weakToWeakObjects()

func cmuxStoredFindSelection(for owner: AnyObject?) -> NSRange? {
    guard let owner else { return nil }
    return cmuxFindSelectionStore.object(forKey: owner)?.rangeValue
}

func cmuxStoreFindSelection(_ range: NSRange, for owner: AnyObject?) {
    guard let owner else { return }
    cmuxFindSelectionStore.setObject(NSValue(range: range), forKey: owner)
}

func cmuxTrackedFindFieldEditorOwner(_ editor: NSTextView) -> FindSelectionTrackingTextField? {
    guard editor.isFieldEditor else { return nil }
    return cmuxFindFieldEditorOwners.object(forKey: editor)
}

func cmuxFindTextFieldOwner(for responder: NSResponder?) -> FindSelectionTrackingTextField? {
    if let field = responder as? FindSelectionTrackingTextField {
        return field
    }
    if let editor = responder as? NSTextView {
        return cmuxTrackedFindFieldEditorOwner(editor) ?? (cmuxFieldEditorOwnerView(editor) as? FindSelectionTrackingTextField)
    }
    return nil
}

@MainActor
func cmuxRememberFindSelectionBeforePanelFocusMove(tabManager: TabManager?, window: NSWindow?) {
    guard let editor = window?.firstResponder as? NSTextView else { return }
    let selection = cmuxClampedFindSelection(editor.selectedRange(), in: editor.string)
    if let field = cmuxTrackedFindFieldEditorOwner(editor),
       let owner = field.cmuxSelectionOwner {
        _ = field.cmuxRememberSelection(selection, in: editor.string)
        cmuxStoreFindSelection(selection, for: owner)
        return
    }
    guard let workspace = tabManager?.selectedWorkspace,
          let focusedPanelId = workspace.focusedPanelId else { return }
    let owner = (workspace.terminalPanel(for: focusedPanelId)?.searchState as AnyObject?) ?? (workspace.browserPanel(for: focusedPanelId)?.searchState as AnyObject?)
    guard let owner else { return }
    cmuxStoreFindSelection(selection, for: owner)
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
    weak var cmuxSelectionOwner: AnyObject?
    var cmuxOnEscape: ((NSTextView) -> Bool)?
    private var cmuxSelectionObserver: NSObjectProtocol?
    private var cmuxKeyMonitor: Any?
    private weak var cmuxObservedEditor: NSTextView?
    private weak var cmuxPreviousEditorNextResponder: NSResponder?

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
        if cmuxLastSelectedRange == nil, cmuxStoredFindSelection(for: cmuxSelectionOwner) == nil {
            _ = cmuxRememberSelectionFromCurrentEditor()
        }
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

    override func cancelOperation(_ sender: Any?) {
        if let editor = currentEditor() as? NSTextView, !editor.hasMarkedText(), cmuxOnEscape?(editor) == true {
            return
        }
        super.cancelOperation(sender)
    }

    func cmuxRememberSelection(_ range: NSRange, in text: String) -> NSRange {
        let selection = cmuxClampedFindSelection(range, in: text)
        cmuxLastSelectedRange = selection
        cmuxStoreFindSelection(selection, for: cmuxSelectionOwner)
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
        cmuxAdoptFieldEditor(editor)
        guard cmuxSelectionObserver == nil else { return }
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
        if let editor = cmuxObservedEditor {
            if editor.nextResponder === self {
                editor.nextResponder = cmuxPreviousEditorNextResponder
            }
            if cmuxTrackedFindFieldEditorOwner(editor) === self {
                cmuxFindFieldEditorOwners.removeObject(forKey: editor)
            }
        }
        cmuxPreviousEditorNextResponder = nil
        cmuxObservedEditor = nil
    }

    private func cmuxAdoptFieldEditor(_ editor: NSTextView) {
        cmuxObservedEditor = editor
        cmuxFindFieldEditorOwners.setObject(self, forKey: editor)
        if editor.nextResponder !== self {
            cmuxPreviousEditorNextResponder = editor.nextResponder
            editor.nextResponder = self
        }
        cmuxInstallKeyMonitorIfNeeded()
    }

    private func cmuxInstallKeyMonitorIfNeeded() {
        guard cmuxKeyMonitor == nil else { return }
        cmuxKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let eventWindow = event.window ?? (event.windowNumber > 0 ? NSApp.window(withWindowNumber: event.windowNumber) : nil)
            guard let self,
                  eventWindow == nil || eventWindow === self.window,
                  let editor = self.currentEditor() as? NSTextView,
                  self.window?.firstResponder === editor else { return event }
            if cmuxFindEventIsPlainEscape(event), !editor.hasMarkedText(), self.cmuxOnEscape?(editor) == true { return nil }
            DispatchQueue.main.async { [weak self, weak editor] in
                guard let self, let editor else { return }
                _ = self.cmuxRememberSelection(from: editor)
            }
            return event
        }
    }

    private func cmuxRemoveKeyMonitor() {
        if let cmuxKeyMonitor {
            NSEvent.removeMonitor(cmuxKeyMonitor)
            self.cmuxKeyMonitor = nil
        }
    }

    private func cmuxRestoreRememberedSelection() {
        guard let rememberedSelection = cmuxStoredFindSelection(for: cmuxSelectionOwner) ?? cmuxLastSelectedRange else { return }
        if let editor = currentEditor() as? NSTextView, !editor.hasMarkedText() {
            let selection = cmuxRememberSelection(rememberedSelection, in: editor.string)
            editor.setSelectedRange(selection)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let editor = self.currentEditor() as? NSTextView,
                  !editor.hasMarkedText() else { return }
            let selection = self.cmuxRememberSelection(rememberedSelection, in: editor.string)
            editor.setSelectedRange(selection)
        }
    }
}
