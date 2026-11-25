#if os(iOS)
import UIKit

/// A hold on drawn text selects it in place, as text does everywhere else on iOS: the word under
/// the finger is selected with handles, the loupe follows the finger while it is held and drags
/// the selection out word by word, and on lift the edit menu (Copy, Select All, Look Up, Share,
/// then the `extraMenu` rows) points at the selection. Nothing lifts, no block is selected whole.
///
/// Leo, 2026-11-23: "holding shouldnt raise the whole bubble of a chunk of text being selected ...
/// just hold and it should highlight text as normal then you select some bits". It replaces the
/// context menu and Select Text sheet of CMUX-33 on chat text.
///
/// The text stays drawn by its `UILabel`s (cheap to scroll). Only while a selection lives does a
/// read-only `UITextView` with the label's text and frame stand in for the held label; it goes
/// away, and the label shows again, when the selection is cleared or another one starts.
@MainActor
public final class InPlaceTextSelection: NSObject {
    /// The hold before a selection starts: the system's text hold (`UITextView`'s is 0.5 s; a
    /// shorter one starts before the transcript's scroll pan would).
    public static let pressDuration: TimeInterval = 0.45
    /// The accessibility identifier of the stand-in text view (UI tests find the selection by it).
    public static let identifier = "chat.inPlaceSelection"

    /// The one live selection in the app: a new one ends it.
    private static weak var current: InPlaceTextSelection?

    public let press: UILongPressGestureRecognizer
    private weak var host: UIView?
    /// The labels a hold can select from, in `host`'s subtree, front-most last.
    private let labels: () -> [UILabel]
    /// Rows the edit menu shows after the system's for the held label (its message's actions).
    public var extraMenu: ((UILabel) -> [UIMenuElement])?
    /// Called when a selection starts and ends (a row can stop its own taps meanwhile).
    public var onChange: ((Bool) -> Void)?

    private var overlay: StandInTextView?
    private weak var heldLabel: UILabel?
    private var anchor: UITextRange?
    private var loupe: UITextLoupeSession?
    private var pressing = false
    private lazy var menu = UIEditMenuInteraction(delegate: self)
    /// A tap anywhere else in the window ends the selection, as in Messages and Notes. A read-only
    /// text view stays first responder through taps outside it, so without this the selection
    /// lived on (fleet simulator step 56d846f0a93209464c930cb8). It never takes the tap from what
    /// it lands on.
    private lazy var outsideTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedOutside(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        return tap
    }()

    public init(host: UIView, labels: @escaping () -> [UILabel]) {
        self.host = host
        self.labels = labels
        press = UILongPressGestureRecognizer()
        super.init()
        press.minimumPressDuration = Self.pressDuration
        press.addTarget(self, action: #selector(pressed(_:)))
        press.delegate = self
        host.addGestureRecognizer(press)
    }

    /// True while a selection is shown.
    public var isSelecting: Bool { overlay != nil }

    /// The label under `point` (in `host`), if a hold there would select text.
    public func label(at point: CGPoint) -> UILabel? {
        guard let host else { return nil }
        return labels().last { label in
            guard !label.isHidden, label.alpha > 0.01, label.window != nil, (label.attributedText?.length ?? 0) > 0 else { return false }
            return label.bounds.insetBy(dx: -4, dy: -4).contains(host.convert(point, to: label))
        }
    }

    /// Clears the selection and shows the label again (a row reconfigured or reused calls it).
    public func end() {
        loupe?.invalidate()
        loupe = nil
        pressing = false
        anchor = nil
        guard let overlay else { return }
        self.overlay = nil
        overlay.onResign = nil
        overlay.delegate = nil
        if overlay.isFirstResponder { _ = overlay.resignFirstResponder() }
        overlay.removeFromSuperview()
        outsideTap.view?.removeGestureRecognizer(outsideTap)
        heldLabel?.alpha = 1
        heldLabel = nil
        if Self.current === self { Self.current = nil }
        onChange?(false)
    }

    @objc private func pressed(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began: begin(at: press)
        case .changed: extend(to: press)
        case .ended: lift()
        case .cancelled, .failed:
            loupe?.invalidate()
            loupe = nil
            pressing = false
        default: break
        }
    }

    private func begin(at press: UILongPressGestureRecognizer) {
        guard let host, let label = label(at: press.location(in: host)), let parent = label.superview else { return }
        if Self.current !== self { Self.current?.end() }
        end()
        let view = StandInTextView(standingInFor: label)
        view.delegate = self
        view.addInteraction(menu)
        parent.insertSubview(view, aboveSubview: label)
        label.alpha = 0
        overlay = view
        heldLabel = label
        Self.current = self
        pressing = true
        view.onResign = { [weak self] in self?.end() }
        host.window?.addGestureRecognizer(outsideTap)
        _ = view.becomeFirstResponder()
        let point = press.location(in: view)
        guard let word = Self.word(in: view, at: point) else { end(); return }
        anchor = word
        view.selectedTextRange = word
        loupe = UITextLoupeSession.begin(at: point, fromSelectionWidgetView: nil, in: view)
        UISelectionFeedbackGenerator().selectionChanged()
        onChange?(true)
    }

    private func extend(to press: UILongPressGestureRecognizer) {
        guard let view = overlay, let anchor, pressing else { return }
        let point = press.location(in: view)
        if let word = Self.word(in: view, at: point) {
            let start = view.compare(word.start, to: anchor.start) == .orderedAscending ? word.start : anchor.start
            let end = view.compare(word.end, to: anchor.end) == .orderedDescending ? word.end : anchor.end
            if let range = view.textRange(from: start, to: end), range != view.selectedTextRange {
                view.selectedTextRange = range
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
        let caret = view.selectedTextRange.map { view.caretRect(for: $0.end) } ?? .zero
        loupe?.move(to: point, withCaretRect: caret, trackingCaret: false)
    }

    private func lift() {
        loupe?.invalidate()
        loupe = nil
        pressing = false
        guard let view = overlay, let range = view.selectedTextRange, !range.isEmpty else { return }
        let rect = Self.rect(of: range, in: view)
        menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.minY)))
    }

    @objc private func tappedOutside(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, let overlay else { return }
        // Handles hang about 20 pt past the text's ends: a tap there is the selection's own.
        guard !overlay.bounds.insetBy(dx: -24, dy: -24).contains(tap.location(in: overlay)) else { return }
        // After the tap's own target has run (an edit-menu row acts on the live selection first).
        DispatchQueue.main.async { [weak self, weak overlay] in
            guard let self, let overlay, self.overlay === overlay else { return }
            self.end()
        }
    }

    /// The word at `point` in `view`, else the nearest one before it, else one character.
    static func word(in view: UITextView, at point: CGPoint) -> UITextRange? {
        guard let position = view.closestPosition(to: point) else { return nil }
        let tokenizer = view.tokenizer
        if let word = tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: .storage(.forward)) { return word }
        if let word = tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: .storage(.backward)) { return word }
        if let next = view.position(from: position, offset: 1) { return view.textRange(from: position, to: next) }
        if let previous = view.position(from: position, offset: -1) { return view.textRange(from: previous, to: position) }
        return nil
    }

    static func rect(of range: UITextRange, in view: UITextView) -> CGRect {
        view.selectionRects(for: range).map(\.rect).filter { !$0.isEmpty }.reduce(CGRect.null) { $0.union($1) }
    }
}

extension InPlaceTextSelection: UIGestureRecognizerDelegate {
    public func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === press, let host else { return true }
        // A hold inside the live selection is the text view's own (it moves a handle or the range).
        if let overlay, overlay.bounds.contains(recognizer.location(in: overlay)) { return false }
        return label(at: recognizer.location(in: host)) != nil
    }

    public func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        recognizer === outsideTap
    }

    public func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard recognizer === outsideTap else { return true }
        // Only the app's content: the edit menu's rows sit outside the root view and act on the selection.
        guard let root = host?.window?.rootViewController?.view, let view = touch.view else { return false }
        return view.isDescendant(of: root)
    }
}

extension InPlaceTextSelection: UITextViewDelegate {
    public func textViewDidChangeSelection(_ textView: UITextView) {
        // A tap in the text collapses the selection: that is the end of it, as in Messages.
        guard !pressing, textView.selectedRange.length == 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let overlay = self.overlay, overlay === textView, overlay.selectedRange.length == 0 else { return }
            self.end()
        }
    }

    public func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: suggestedActions + extras())
    }

    private func extras() -> [UIMenuElement] {
        guard let heldLabel, let rows = extraMenu?(heldLabel), !rows.isEmpty else { return [] }
        return [UIMenu(options: .displayInline, children: rows)]
    }
}

extension InPlaceTextSelection: @MainActor UIEditMenuInteractionDelegate {
    public func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                                    suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: suggestedActions + extras())
    }

    public func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        guard let view = overlay, let range = view.selectedTextRange else { return .null }
        return Self.rect(of: range, in: view)
    }
}

/// A read-only text view drawn exactly as the `UILabel` it stands in for: the same text, frame,
/// line breaks and colors (links keep the label's look), no insets, no scrolling.
@MainActor
final class StandInTextView: UITextView {
    var onResign: (() -> Void)?

    init(standingInFor label: UILabel) {
        super.init(frame: label.frame, textContainer: nil)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = label.lineBreakMode == .byClipping ? .byClipping : .byWordWrapping
        linkTextAttributes = [:]
        dataDetectorTypes = []
        // The label's attributes, with its own font, color and alignment where a run has none.
        let text = NSMutableAttributedString(attributedString: label.attributedText ?? NSAttributedString())
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.font, in: whole) { value, range, _ in
            if value == nil, let font = label.font { text.addAttribute(.font, value: font, range: range) }
        }
        text.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            if value == nil { text.addAttribute(.foregroundColor, value: label.textColor ?? .label, range: range) }
        }
        if label.textAlignment != .natural {
            text.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
                guard value == nil else { return }
                let style = NSMutableParagraphStyle()
                style.alignment = label.textAlignment
                text.addAttribute(.paragraphStyle, value: style, range: range)
            }
        }
        attributedText = text
        accessibilityIdentifier = InPlaceTextSelection.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    #if DEBUG
    /// UI tests read the selected text (a range, never the whole text) as the label.
    override var accessibilityLabel: String? {
        get { selectedRange.length > 0 ? (text as NSString).substring(with: selectedRange) : "" }
        set {}
    }
    #endif

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign?() }
        return resigned
    }
}
#endif
