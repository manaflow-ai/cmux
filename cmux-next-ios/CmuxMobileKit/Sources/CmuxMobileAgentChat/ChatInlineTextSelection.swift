#if os(iOS)
import UIKit

/// Holding on transcript text selects the word under the finger in place, with the system's
/// handles and edit menu, as text does everywhere on iOS (Leo, 2026-11-23: holding should
/// highlight text as normal, never lift the whole bubble or select a chunk).
///
/// A transparent, selectable `UITextView` laid exactly over the label that draws the text: the
/// label keeps drawing it (links, marks) and only the highlight and handles show. The row's own
/// actions (Copy message, Share, Edit and Resend...) follow the system's in the edit menu, so
/// everything the old long-press menu offered is still a hold away.
@MainActor
final class ChatInlineTextSelection: UITextView, UITextViewDelegate, UIEditMenuInteractionDelegate {
    /// The label's text, for Copy (the overlay's own copy is drawn clear).
    private let plainText: String
    /// The row's actions, shown after the system's in the edit menu.
    private let rowActions: () -> [UIMenuElement]
    var onEnd: (() -> Void)?
    private var ended = false
    /// The press's starting word: dragging during the hold extends from it.
    private var anchor: NSRange?
    private lazy var menuInteraction = UIEditMenuInteraction(delegate: self)

    init(over label: UILabel, rowActions: @escaping () -> [UIMenuElement]) {
        let text = label.attributedText ?? NSAttributedString(string: label.text ?? "")
        plainText = text.string
        self.rowActions = rowActions
        super.init(frame: label.frame, textContainer: nil)
        let clear = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: clear.length)
        clear.removeAttribute(.link, range: whole)
        clear.addAttribute(.foregroundColor, value: UIColor.clear, range: whole)
        attributedText = clear
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = label.lineBreakMode
        delegate = self
        accessibilityIdentifier = "chat.textSelection"
        accessibilityLabel = String(localized: "mobile.agentChat.selection.label", defaultValue: "Selected text", bundle: .module)
        addInteraction(menuInteraction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// VoiceOver (and UI tests) read what is selected.
    override var accessibilityValue: String? {
        get { Range(selectedRange, in: plainText).map { String(plainText[$0]) } }
        set {}
    }

    /// The word at `point` (in this view), or the nearest character when there is none there.
    func range(at point: CGPoint) -> NSRange? {
        guard let position = closestPosition(to: point) else { return nil }
        let word = tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: .storage(.forward))
            ?? tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: .storage(.backward))
        if let word {
            return NSRange(location: offset(from: beginningOfDocument, to: word.start), length: offset(from: word.start, to: word.end))
        }
        let index = offset(from: beginningOfDocument, to: position)
        let length = (plainText as NSString).length
        guard length > 0 else { return nil }
        return NSRange(location: min(index, length - 1), length: 1)
    }

    /// Selects the word at `point`; false when the text has none.
    @discardableResult
    func selectWord(at point: CGPoint) -> Bool {
        guard let word = range(at: point) else { return false }
        _ = becomeFirstResponder()
        anchor = word
        selectedRange = word
        return true
    }

    /// The finger moved during the hold: the selection runs from the first word to the word under it.
    func extend(to point: CGPoint) {
        guard let anchor, let word = range(at: point) else { return }
        selectedRange = NSUnionRange(anchor, word)
        menuInteraction.dismissMenu()
    }

    /// The edit menu, under or over the selection.
    func showEditMenu() {
        let rects = selectedTextRange.map { selectionRects(for: $0).map(\.rect).filter { !$0.isEmpty } } ?? []
        let selection = rects.dropFirst().reduce(rects.first ?? bounds) { $0.union($1) }
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: selection.midX, y: selection.minY))
        menuInteraction.presentEditMenu(with: configuration)
    }

    override func copy(_ sender: Any?) {
        guard let range = Range(selectedRange, in: plainText) else { return }
        UIPasteboard.general.string = String(plainText[range])
    }

    private func menu(_ suggested: [UIMenuElement]) -> UIMenu {
        let row = rowActions()
        guard !row.isEmpty else { return UIMenu(children: suggested) }
        return UIMenu(children: suggested + [UIMenu(options: .displayInline, children: row)])
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        menu(suggestedActions)
    }

    /// The menu UIKit shows itself after a handle moves.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        menu(suggestedActions)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        // Tapping the selection away (any collapse) ends it.
        if selectedRange.length == 0 { end() }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { end() }
        return resigned
    }

    func end() {
        guard !ended else { return }
        ended = true
        menuInteraction.dismissMenu()
        removeFromSuperview()
        onEnd?()
    }
}

/// Starts and tracks a hold-to-select on a set of labels: the long press's began selects the word,
/// changed extends the selection, ended shows the edit menu.
@MainActor
final class ChatInlineSelectionDriver {
    private(set) var selection: ChatInlineTextSelection?

    /// The hold's began: a selection over `label`'s word at `point` (in `container`), placed in
    /// `container` over the label. False when the label has no text there.
    @discardableResult
    func begin(on label: UILabel, at point: CGPoint, in container: UIView, rowActions: @escaping () -> [UIMenuElement]) -> Bool {
        end()
        let view = ChatInlineTextSelection(over: label, rowActions: rowActions)
        view.frame = label.convert(label.bounds, to: container)
        container.addSubview(view)
        view.layoutIfNeeded()
        guard view.selectWord(at: container.convert(point, to: view)) else {
            view.end()
            return false
        }
        view.onEnd = { [weak self, weak view] in
            if let self, self.selection === view { self.selection = nil }
        }
        selection = view
        UISelectionFeedbackGenerator().selectionChanged()
        return true
    }

    func track(_ press: UILongPressGestureRecognizer) {
        guard let selection else { return }
        switch press.state {
        case .changed: selection.extend(to: press.location(in: selection))
        case .ended: selection.showEditMenu()
        default: break
        }
    }

    func end() {
        selection?.end()
        selection = nil
    }
}
#endif
