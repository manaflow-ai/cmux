#if os(iOS)
import CmuxMobileDesign
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
final class ChatInlineTextSelection: UITextView, UITextViewDelegate, @MainActor UIEditMenuInteractionDelegate {
    /// The label's text, for Copy (the overlay's own copy is drawn clear).
    private let plainText: String
    /// The row's actions, shown after the system's in the edit menu.
    private let rowActions: () -> [UIMenuElement]
    var onEnd: (() -> Void)?
    private var ended = false
    /// The press's starting word: dragging during the hold extends from it.
    private var anchor: NSRange?
    private lazy var menuInteraction = UIEditMenuInteraction(delegate: self)
    private lazy var outsideTap = SelectionOutsideTap(selection: self) { [weak self] in self?.end() }

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
        textContainer.maximumNumberOfLines = label.numberOfLines
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

    /// A tap anywhere else in the window ends it (a read-only text view keeps first responder
    /// through taps outside it, and a tap in another row never reached this row's tap).
    override func didMoveToWindow() {
        super.didMoveToWindow()
        outsideTap.attach(to: window)
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
    /// The one live selection in the transcript: a hold in another row ends it.
    private static weak var live: ChatInlineTextSelection?
    private(set) var selection: ChatInlineTextSelection?
    /// Called with the live selection when one starts and nil when it ends: the row lists it
    /// among its accessibility elements meanwhile (its explicit list would hide it from
    /// VoiceOver and UI tests, fleet simulator step 56d846f0a93209464c930cb8).
    var onChange: ((ChatInlineTextSelection?) -> Void)?

    /// The hold's began: a selection over `label`'s word at `point` (in `container`), placed in
    /// `container` over the label. False when the label has no text there.
    @discardableResult
    func begin(on label: UILabel, at point: CGPoint, in container: UIView, rowActions: @escaping () -> [UIMenuElement]) -> Bool {
        end()
        Self.live?.end()
        let view = ChatInlineTextSelection(over: label, rowActions: rowActions)
        view.frame = label.convert(label.bounds, to: container)
        container.addSubview(view)
        view.layoutIfNeeded()
        guard view.selectWord(at: container.convert(point, to: view)) else {
            view.end()
            return false
        }
        view.onEnd = { [weak self, weak view] in
            guard let self, self.selection === view else { return }
            self.selection = nil
            self.onChange?(nil)
        }
        selection = view
        Self.live = view
        onChange?(view)
        CmuxMobileHaptics().selectionChanged()
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
/// Ends a selection on a tap anywhere else in its window, as in Messages and Notes, without taking
/// the tap from what it lands on. Taps on the selection (and its handles, about 20 pt past the
/// text) and on the edit menu (outside the root view) are the selection's own.
@MainActor
final class SelectionOutsideTap: NSObject, UIGestureRecognizerDelegate {
    private weak var selection: UIView?
    private let onOutside: @MainActor () -> Void
    private lazy var tap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        return tap
    }()

    init(selection: UIView, onOutside: @escaping @MainActor () -> Void) {
        self.selection = selection
        self.onOutside = onOutside
    }

    /// Watches `window` (nil stops watching).
    func attach(to window: UIWindow?) {
        tap.view?.removeGestureRecognizer(tap)
        window?.addGestureRecognizer(tap)
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, let selection else { return }
        guard !selection.bounds.insetBy(dx: -24, dy: -24).contains(tap.location(in: selection)) else { return }
        // After the tap's own target has run.
        DispatchQueue.main.async { [weak self] in self?.onOutside() }
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let root = selection?.window?.rootViewController?.view, let view = touch.view else { return false }
        return view.isDescendant(of: root)
    }
}
#endif
