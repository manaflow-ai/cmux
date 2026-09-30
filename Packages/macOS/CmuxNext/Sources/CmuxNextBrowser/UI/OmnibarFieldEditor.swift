import AppKit

/// What the omnibar's field editor reports. Every user change becomes one
/// `OmnibarInput`; the state machine decides what it means.
@MainActor protocol OmnibarFieldEditorSink: AnyObject {
    /// Text or marked text (`kind` set) or only the selection (nil) changed.
    func fieldEditorDidChange(kind: OmnibarState.EditKind?)
    /// A key the state machine may take first. Returns true when handled.
    func fieldEditorKey(_ key: OmnibarInput.Key) -> Bool
    func fieldEditorMouseDown(clickCount: Int)
    func fieldEditorMouseUp()
    var canUndo: Bool { get }
    var canRedo: Bool { get }
}

/// The omnibar's own field editor (`AddressFieldCell` hands it out instead
/// of the window's shared one). It reports edits with their kind, IME
/// composition, final selections, clicks, Return with modifiers and undo,
/// and has AppKit undo off: the state machine owns the text and its undo.
final class OmnibarFieldEditor: NSTextView {
    weak var sink: (any OmnibarFieldEditorSink)?
    /// Between `shouldChangeText` and `didChangeText`: selection changes
    /// there belong to the edit and are reported with it.
    private var isChangingText = false
    private var isPasting = false
    private var kind: OmnibarState.EditKind = .insert

    convenience init() {
        self.init(frame: .zero)
        isFieldEditor = true
        isRichText = false
        importsGraphics = false
    }

    /// AppKit turns undo on for every field editor it sets up; the state
    /// machine owns undo, so this one never registers AppKit undo actions.
    override var allowsUndo: Bool {
        get { false }
        set {}
    }

    // MARK: Edits

    override func shouldChangeText(in range: NSRange, replacementString: String?) -> Bool {
        let accepted = super.shouldChangeText(in: range, replacementString: replacementString)
        if accepted {
            isChangingText = true
            if isPasting {
                kind = .paste
            } else if replacementString?.isEmpty == true, range.length > 0 {
                kind = .delete
            } else {
                kind = .insert
            }
        }
        return accepted
    }

    override func didChangeText() {
        isChangingText = false
        // Posts NSText.didChangeNotification: the field's delegate reports it.
        super.didChangeText()
    }

    /// The kind of the edit that just finished.
    var lastEditKind: OmnibarState.EditKind { kind }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        isChangingText = false
        sink?.fieldEditorDidChange(kind: .insert)
    }

    override func unmarkText() {
        super.unmarkText()
        isChangingText = false
        sink?.fieldEditorDidChange(kind: .insert)
    }

    override func paste(_ sender: Any?) {
        isPasting = true
        defer { isPasting = false }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        isPasting = true
        defer { isPasting = false }
        super.pasteAsPlainText(sender)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // Drags report once, when they end; edits report through didChangeText.
        guard !stillSelecting, !isChangingText else { return }
        sink?.fieldEditorDidChange(kind: nil)
    }

    // MARK: Keys and mouse

    override func keyDown(with event: NSEvent) {
        // Return with modifiers never reaches doCommandBy as a plain newline.
        if event.keyCode == 36 || event.keyCode == 76, !hasMarkedText(),
           sink?.fieldEditorKey(.enter(.init(event.modifierFlags))) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        sink?.fieldEditorMouseDown(clickCount: event.clickCount)
        // Tracks the click or drag until mouse-up.
        super.mouseDown(with: event)
        sink?.fieldEditorMouseUp()
    }

    @objc func undo(_ sender: Any?) {
        _ = sink?.fieldEditorKey(.undo)
    }

    @objc func redo(_ sender: Any?) {
        _ = sink?.fieldEditorKey(.redo)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case Selector(("undo:")): sink?.canUndo ?? false
        case Selector(("redo:")): sink?.canRedo ?? false
        default: super.validateUserInterfaceItem(item)
        }
    }
}

/// Hands the omnibar its own field editor.
final class AddressFieldCell: NSTextFieldCell {
    let editor = OmnibarFieldEditor()

    override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }
}

extension OmnibarInput.Disposition {
    /// Chrome on macOS: Cmd background tab, Shift-Cmd or Option foreground
    /// tab, Shift new window.
    init(_ flags: NSEvent.ModifierFlags) {
        let flags = flags.intersection([.command, .shift, .option])
        if flags.contains(.command) {
            self = flags.contains(.shift) ? .newForegroundTab : .newBackgroundTab
        } else if flags.contains(.option) {
            self = .newForegroundTab
        } else if flags.contains(.shift) {
            self = .newWindow
        } else {
            self = .currentTab
        }
    }
}
