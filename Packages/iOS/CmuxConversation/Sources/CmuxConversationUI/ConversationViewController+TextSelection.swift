#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// The long-press menu's "Select": Messages selects the bubble's whole text
/// in place, with grab handles and the system edit menu (Copy, Look Up,
/// Translate, more), instead of entering multi-message select mode ("More…").
///
/// A transparent, selectable `UITextView` laid exactly over the bubble's
/// label supplies the system selection UI; the label keeps drawing the text
/// (effects, mentions, links) underneath, so nothing visibly changes but the
/// highlight and handles.
final class BubbleTextSelectionView: UITextView, UITextViewDelegate {
    let rowID: String
    /// The bubble's own text, for Copy (the overlay's copy is drawn clear).
    private let plainText: String
    var onEnd: (() -> Void)?
    private var ended = false
    /// UITextView keeps its own edit menu private; this one (no delegate)
    /// gathers the same system actions from the responder chain: Copy,
    /// Look Up, Translate, Share.
    private let menuInteraction = UIEditMenuInteraction(delegate: nil)

    init(rowID: String, text: NSAttributedString, tint: UIColor) {
        self.rowID = rowID
        plainText = text.string
        super.init(frame: .zero, textContainer: nil)
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
        tintColor = tint
        delegate = self
        // VoiceOver already reads (and offers Copy on) the bubble itself.
        accessibilityElementsHidden = true
        addInteraction(menuInteraction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Selects every character and shows the edit menu above it.
    func selectAllAndShowMenu() {
        _ = becomeFirstResponder()
        selectedRange = NSRange(location: 0, length: (text as NSString).length)
        showEditMenu()
    }

    func showEditMenu() {
        let rect = selectedTextRange.map { firstRect(for: $0) } ?? bounds
        let point = CGPoint(x: rect.midX, y: rect.minY)
        menuInteraction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    /// Copies what the bubble shows, as plain text (the overlay's own
    /// attributes are transparent).
    override func copy(_ sender: Any?) {
        guard let range = Range(selectedRange, in: plainText) else { return }
        UIPasteboard.general.string = String(plainText[range])
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        // Tapping the selection away (or any collapse) ends it, as in Messages.
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
        onEnd?()
    }
}

extension ConversationViewController {
    /// Whether "Select" applies: the row draws text in a bubble.
    func canSelectText(in cell: MessageCell) -> Bool {
        !cell.textLabel.isHidden && cell.cellLayout?.textFrame != nil && (cell.textLabel.attributedText?.length ?? 0) > 0
    }

    func beginTextSelection(rowID: String) {
        endTextSelection()
        guard let indexPath = indexPath(for: rowID),
              let cell = collectionView.cellForItem(at: indexPath) as? MessageCell,
              let model = cell.model, canSelectText(in: cell),
              let text = cell.textLabel.attributedText else { return }
        // The keyboard would cover the menu; Messages dismisses it too.
        composer.textView.resignFirstResponder()
        let selection = BubbleTextSelectionView(
            rowID: rowID,
            text: text,
            tint: model.isOutgoing ? .white : .systemBlue
        )
        selection.frame = cell.textLabel.convert(cell.textLabel.bounds, to: collectionView)
        selection.onEnd = { [weak self, weak selection] in
            guard let self, let selection else { return }
            if self.textSelection === selection { self.textSelection = nil }
            selection.removeFromSuperview()
        }
        collectionView.addSubview(selection)
        textSelection = selection
        selection.selectAllAndShowMenu()
    }

    func endTextSelection() {
        guard let selection = textSelection else { return }
        textSelection = nil
        selection.end()
    }

    /// Touches meant for the selection (handles, the text, the loupe) stay
    /// with it instead of starting the transcript's own gestures.
    func touchBelongsToTextSelection(_ point: CGPoint) -> Bool {
        guard let selection = textSelection else { return false }
        // Grab handles hang ~20 pt past the text's ends.
        return selection.frame.insetBy(dx: -24, dy: -24).contains(point)
    }
}
#endif
