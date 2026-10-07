#if os(macOS)
import AppKit

/// A bubble's text: drawn exactly as `MacMeasuredTextView` draws it (so
/// bubbles keep the metrics `boundingRect` measured), but selectable like the
/// text in a Messages bubble. AppKit supplies the selection tracking
/// (drag, double-click word, triple-click paragraph, Shift-arrows), Copy,
/// Look Up, Translate, Services and dragging the selected text out.
/// Selection never spans bubbles, as in Messages.
final class MacBubbleTextView: NSTextView {
    /// The text as laid out and drawn.
    var attributedText: NSAttributedString {
        get { textStorage.map { NSAttributedString(attributedString: $0) } ?? NSAttributedString() }
        set {
            guard let textStorage, !textStorage.isEqual(to: newValue) else { return }
            // New text (a reused row, an edit) drops any selection in the old.
            setSelectedRange(NSRange(location: 0, length: 0))
            textStorage.setAttributedString(newValue)
            needsDisplay = true
        }
    }

    init() {
        // TextKit 1, so hit testing and selection rects come from the same
        // NSLayoutManager metrics the transcript uses for links.
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        super.init(frame: .zero, textContainer: container)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        focusRingType = .none
        // Selection is painted in draw(_:); attribute changes would restyle the text.
        selectedTextAttributes = [:]
        // The row is the accessibility element for the message.
        setAccessibilityElement(false)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The transcript this bubble belongs to (nil inside the thread focus).
    private var transcript: MacTranscriptTableView? {
        var view = superview
        while let current = view {
            if let table = current as? MacTranscriptTableView { return table }
            view = current.superview
        }
        return nil
    }

    var isOutgoing = false

    private var selectionColor: NSColor {
        // On the blue outgoing bubble the system highlight would vanish.
        isOutgoing ? NSColor.white.withAlphaComponent(0.35) : NSColor.selectedTextBackgroundColor
    }

    override func draw(_ dirtyRect: NSRect) {
        let range = selectedRange()
        if range.length > 0, let manager = layoutManager, let container = textContainer {
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            // draw(_:) runs under this view's appearance, so dynamic colors resolve here.
            selectionColor.setFill()
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: container) { rect, _ in
                rect.fill()
            }
        }
        attributedText.draw(with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
        if selectedRange().length > 0 { transcript?.interaction?.bubbleTextDidSelect(self) }
    }

    // A bubble never scrolls the transcript it sits in: NSTextView keeps its
    // caret visible by scrolling the enclosing scroll view on every resize
    // and selection drag, which here is the whole conversation.
    override func scrollToVisible(_ rect: NSRect) -> Bool { false }
    override func scrollRangeToVisible(_ range: NSRange) {}
    override func autoscroll(with event: NSEvent) -> Bool { false }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        // Badges, links and press-and-hold keep the transcript's handling;
        // a click or drag that is none of those selects text.
        if let table = transcript, table.interaction?.handleClick(event, in: table) == true { return }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let selection = selectedRange()
        let inSelection = selection.length > 0 && index >= selection.location && index <= NSMaxRange(selection)
        if !inSelection, selection.length > 0 { setSelectedRange(NSRange(location: 0, length: 0)) }
        let menu = transcript.flatMap { table in table.interaction?.contextMenu(for: event, in: table) } ?? NSMenu()
        guard inSelection, let system = super.menu(for: event) else { return menu.items.isEmpty ? nil : menu }
        // Messages adds the system text services (Look Up, Translate,
        // Search, Share, Speech, Services) for selected text; editing and
        // styling items never apply to a sent bubble.
        let editing: Set<Selector> = [
            #selector(cut(_:)), #selector(copy(_:)), #selector(paste(_:)), #selector(pasteAsPlainText(_:)),
            #selector(NSFontManager.addFontTrait(_:)), #selector(showGuessPanel(_:)), #selector(orderFrontSubstitutionsPanel(_:)),
            #selector(toggleContinuousSpellChecking(_:)), #selector(changeLayoutOrientation(_:)),
        ]
        func isEditing(_ item: NSMenuItem) -> Bool {
            if let action = item.action, editing.contains(action) { return true }
            guard let submenu = item.submenu else { return false }
            return submenu.items.contains { isEditing($0) }
        }
        var kept = system.items.filter { !isEditing($0) }
        // Collapse separators the filtering left adjacent or trailing.
        kept = kept.enumerated().filter { index, item in
            guard item.isSeparatorItem else { return true }
            return index > 0 && !kept[index - 1].isSeparatorItem
        }.map(\.element)
        while kept.last?.isSeparatorItem == true { kept.removeLast() }
        while kept.first?.isSeparatorItem == true { kept.removeFirst() }
        guard !kept.isEmpty else { return menu }
        for item in kept { system.removeItem(item) }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        for item in kept { menu.addItem(item) }
        return menu
    }

    // MARK: Keyboard

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        // One selection at a time across the transcript, as in Messages.
        if resigned { setSelectedRange(NSRange(location: 0, length: 0)) }
        return resigned
    }

    override func moveUp(_ sender: Any?) { transcript?.interaction?.moveMessageSelection(by: -1) }
    override func moveDown(_ sender: Any?) { transcript?.interaction?.moveMessageSelection(by: 1) }

    override func insertTab(_ sender: Any?) {
        guard let table = transcript else { return super.insertTab(sender) }
        window?.selectKeyView(following: table)
    }

    override func insertBacktab(_ sender: Any?) {
        guard let table = transcript else { return super.insertBacktab(sender) }
        window?.selectKeyView(preceding: table)
    }

    override func cancelOperation(_ sender: Any?) {
        if let interaction = transcript?.interaction {
            interaction.cancelOperation(sender)
        } else {
            setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    /// With no text selected, Copy copies the whole selected message.
    override func copy(_ sender: Any?) {
        if selectedRange().length == 0, let interaction = transcript?.interaction {
            interaction.copyMessage(sender)
            return
        }
        super.copy(sender)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)), selectedRange().length == 0 {
            return transcript?.interaction?.validateMenuItem(menuItem) ?? false
        }
        return super.validateMenuItem(menuItem)
    }
}
#endif
