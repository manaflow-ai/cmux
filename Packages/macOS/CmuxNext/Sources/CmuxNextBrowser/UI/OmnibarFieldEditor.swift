import AppKit

/// What the omnibar's field editor reports. Every user change becomes one
/// `OmnibarInput`; the state machine decides what it means.
@MainActor protocol OmnibarFieldEditorSink: AnyObject {
    /// Text or marked text (`kind` set) or only the selection (nil) changed.
    func fieldEditorDidChange(kind: OmnibarState.EditKind?)
    /// A key the state machine may take first. Returns true when handled.
    func fieldEditorKey(_ key: OmnibarInput.Key) -> Bool
    /// `word`: the word under the press in the text shown now.
    func fieldEditorMouseDown(clickCount: Int, button: OmnibarInput.MouseButton, word: NSRange?)
    func fieldEditorMouseUp()
    /// Copy and Cut text for the selection (Chrome's copy adjustments).
    var copyContent: OmnibarCopy? { get }
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
        // Shift-Delete (forward delete) removes the highlighted history row
        // (Chrome `VKEY_DELETE` with Shift); otherwise it deletes forward.
        if event.keyCode == 117, event.modifierFlags.contains(.shift), !hasMarkedText(),
           sink?.fieldEditorKey(.deleteSuggestion) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        sink?.fieldEditorMouseDown(clickCount: event.clickCount, button: .left, word: word(at: event))
        // Tracks the click or drag until mouse-up.
        super.mouseDown(with: event)
        sink?.fieldEditorMouseUp()
    }

    override func rightMouseDown(with event: NSEvent) {
        sink?.fieldEditorMouseDown(clickCount: event.clickCount, button: .right, word: nil)
        if suppressesContextMenu {
            // Builds the menu (which selects the word under the pointer) but
            // does not run it.
            _ = menu(for: event)
        } else {
            // Selects the word under the pointer (outside the selection) and
            // runs the context menu.
            super.rightMouseDown(with: event)
        }
        sink?.fieldEditorMouseUp()
    }

    /// Automation (`debug.mouse`): skip the context menu, which would run a
    /// modal tracking loop.
    var suppressesContextMenu = false

    private func word(at event: NSEvent) -> NSRange? {
        guard !string.isEmpty else { return nil }
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        guard index != NSNotFound else { return nil }
        return selectionRange(forProposedRange: NSRange(location: min(index, (string as NSString).length), length: 0), granularity: .selectByWord)
    }

    // MARK: Copy

    /// Chrome copies the page URL for the whole untouched URL, elided or
    /// not, and completes a same-host URL with the page's scheme
    /// (`OmniboxViewViews::OnBeforeCutOrCopy`).
    override func copy(_ sender: Any?) {
        guard let content = sink?.copyContent else { return super.copy(sender) }
        write(content)
    }

    override func cut(_ sender: Any?) {
        guard isEditable, let content = sink?.copyContent else { return super.cut(sender) }
        write(content)
        delete(sender)
    }

    /// Where Copy and Cut write (tests use a private pasteboard).
    var pasteboard: NSPasteboard = .general

    private func write(_ content: OmnibarCopy) {
        pasteboard.clearContents()
        if let url = content.url { pasteboard.writeObjects([url as NSURL]) }
        pasteboard.setString(content.text, forType: .string)
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
