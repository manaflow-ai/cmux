import AppKit
import CmuxNextDesign

/// What the omnibar's field editor reports. Every user change becomes one
/// `OmnibarInput`; the state machine decides what it means.
@MainActor protocol OmnibarFieldEditorSink: AnyObject {
    /// Text or marked text (`kind` set) or only the selection (nil) changed.
    func fieldEditorDidChange(kind: OmnibarState.EditKind?)
    /// A key the state machine may take first. Returns true when handled.
    func fieldEditorKey(_ key: OmnibarInput.Key) -> Bool
    /// `word`: the word under the press in the text shown now.
    func fieldEditorMouseDown(clickCount: Int, button: OmnibarInput.MouseButton, word: NSRange?)
    /// The press moved past the drag threshold before its release.
    func fieldEditorMouseDragged()
    func fieldEditorMouseUp()
    /// A drop on the editing field: the bar takes it as a whole (`AddressBarView.acceptDrop`).
    func fieldEditorDrop(_ pasteboard: NSPasteboard) -> Bool
    /// Copy and Cut text for the selection, with the omnibox copy adjustments.
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
    /// Bench marks (`debug.omnibar_bench`): nil outside a bench run.
    var probe: ((String) -> Void)?
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
        // A field editor pads its line by 2 pt a side, as AppKit's shared one does once it edits; a new
        // text view starts at TextKit's 5. The resting address is laid out with this editor's padding
        // (`EditorAlignedTextFieldCell`) before the field first takes the keyboard, so it must already be 2:
        // since 15972f3ebef put the resting line at the title rect, a 5 pt padding drew the address 3 pt right
        // of where focus puts it (OmnibarFocusLayoutShiftTests).
        textContainer?.lineFragmentPadding = 2
    }

    // MARK: Drops

    /// A drop replaces the whole text (Chromium `OmniboxViewViews::PerformDrop`), never inserts at
    /// the pointer: the bar takes it. A drag of the field's own selection stays a text move.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isOwnDrag(sender) ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isOwnDrag(sender) ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if isOwnDrag(sender) { return super.performDragOperation(sender) }
        return sink?.fieldEditorDrop(sender.draggingPasteboard) ?? false
    }

    private func isOwnDrag(_ sender: any NSDraggingInfo) -> Bool {
        (sender.draggingSource as AnyObject?) === self
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
        // A composition hides the placeholder the field's cell draws under this editor.
        (delegate as? NSView)?.needsDisplay = true
        sink?.fieldEditorDidChange(kind: .insert)
    }

    /// Commits a composition. With nothing marked (AppKit and input
    /// methods also call it then) it commits nothing, so it reports no edit:
    /// an edit report turns the shown address into typed text (cx-d0d.87).
    override func unmarkText() {
        let composing = hasMarkedText()
        super.unmarkText()
        guard composing else { return }
        isChangingText = false
        (delegate as? NSView)?.needsDisplay = true
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

    /// The text container's origin, never left of the inset. For a line wider than its clip view AppKit moves the
    /// container one line padding (2 pt) left, so a long address drew 2 pt left of a short one and of the resting
    /// line (`EditorAlignedTextFieldCell`); everything (layout, caret, hit tests) reads this one origin.
    override var textContainerOrigin: NSPoint {
        let origin = super.textContainerOrigin
        return NSPoint(x: max(origin.x, textContainerInset.width), y: origin.y)
    }

    /// A selection or caret at the line's start (focus selects the whole address; Cmd-A; Cmd-Left) shows the line
    /// from its start, on the resting field's pixels, as Chrome's omnibox does; any other range scrolls as AppKit does.
    /// For a line wider than the field AppKit clamps the clip view to its document and moves the text container 2 pt
    /// left, which put a long address 5 pt left of its resting place on focus and back on blur (Lawrence 2026-11-20).
    override func scrollRangeToVisible(_ range: NSRange) {
        guard range.location == 0 else { return super.scrollRangeToVisible(range) }
        scrollToLineStart()
    }

    /// Moves the clip view so the text container's origin lands on the field's title rect, where
    /// `EditorAlignedTextFieldCell` draws the resting line. That origin can lie left of the clip view's document rect,
    /// where `NSClipView.scroll(to:)` would clamp it, so the bounds are set directly.
    private func scrollToLineStart() {
        guard let clip = superview as? NSClipView, let field = delegate as? NSTextField, let cell = field.cell else { return }
        let start = convert(textContainerOrigin, to: field).x
        let shift = start - cell.titleRect(forBounds: field.bounds).minX
        guard abs(shift) > 0.01 else { return }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x + shift, y: clip.bounds.origin.y))
        field.needsDisplay = true
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting, ranges.count == 1, ranges[0].rangeValue.location == 0 { scrollToLineStart() }
        // Drags report once, when they end; edits report through didChangeText.
        guard !stillSelecting, !isChangingText else { return }
        sink?.fieldEditorDidChange(kind: nil)
    }

    // MARK: Keys and mouse

    override func keyDown(with event: NSEvent) {
        // Return with modifiers never reaches doCommandBy as a plain newline.
        if event.keyCode == 36 || event.keyCode == 76, !hasMarkedText() {
            let disposition = OmnibarInput.Disposition(event.modifierFlags)
            // Control-Return adds www. and .com (Chromium's desired TLD).
            let key: OmnibarInput.Key = event.modifierFlags.contains(.control) ? .enterAddingTLD(disposition) : .enter(disposition)
            if sink?.fieldEditorKey(key) == true { return }
        }
        // Shift-Delete (forward delete) removes the highlighted history row
        // (Chromium `VKEY_DELETE` with Shift); otherwise it deletes forward.
        if event.keyCode == 117, event.modifierFlags.contains(.shift), !hasMarkedText(),
           sink?.fieldEditorKey(.deleteSuggestion) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        probe?("editor.mouseDown")
        sink?.fieldEditorMouseDown(clickCount: event.clickCount, button: .left, word: word(at: event))
        probe?("editor.tracking")
        // Tracks the click or drag until mouse-up.
        super.mouseDown(with: event)
        probe?("editor.tracked")
        if event.omnibarDragged(to: NSApp.currentEvent) { sink?.fieldEditorMouseDragged() }
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

    /// Copies the page URL for the whole untouched URL, elided or not, and
    /// completes a same-host URL with the page's scheme (Chromium
    /// `OmniboxViewViews::OnBeforeCutOrCopy`).
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

/// Hands the omnibar its own field editor. The resting address is drawn where that editor draws
/// it (`EditorAlignedTextFieldCell`), so focus moves no pixel of the address: with the bundled
/// Inter at 14 pt the editor's baseline sits 1 pt below the cell's string drawing (-1 to +3 pt
/// from 12 to 18 pt).
final class AddressFieldCell: EditorAlignedTextFieldCell {
    let editor = OmnibarFieldEditor()

    /// A long address fades out before the star and the toolbar buttons, as a tab's title fades before its edge
    /// (`MarqueeLabel.fadeWidth`).
    override var overflowFadeWidth: CGFloat { Metrics.space6 }

    /// No expansion tool tip: AppKit's hover window redrew a truncated address's whole text on top of the star and
    /// the toolbar buttons, off the field's own line, until a click (Lawrence 2026-11-20). The address fades instead.
    override func expansionFrame(withFrame cellFrame: NSRect, in view: NSView) -> NSRect { .zero }

    override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }
}

extension OmnibarInput.Disposition {
    /// Cmd background tab, Shift-Cmd or Option foreground
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
