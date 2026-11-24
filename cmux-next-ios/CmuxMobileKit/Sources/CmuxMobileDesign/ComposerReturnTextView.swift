#if os(iOS)
import UIKit

/// A composer's growing text view that follows a `ComposerReturnPolicy`:
/// hardware Return, Shift-Return and Option-Return are key commands (each
/// decided by the policy), and the on-screen keyboard's Return reaches the
/// delegate as a "\n" insertion, which `returnShouldInsert(_:)` decides.
/// While text is being composed (marked text, as in Japanese or Chinese
/// input), Return belongs to the input method and the commands step aside.
/// Shows a placeholder while empty.
///
/// Its height follows `ComposerFieldHeight` (`fittingSize(proposedWidth:)`):
/// it grows a line at a time up to the policy's `maxLines`, then scrolls
/// inside. Scrolling stays on at every height, so the text is always clipped
/// to the field and the caret line kept inside it; while the text fits, the
/// view is held at its top, so a stale offset from a frame that had not grown
/// yet never shows. Nothing here toggles a property that changes the view's
/// measured size, so measuring it never feeds back into another layout.
open class ComposerReturnTextView: UITextView {
    public var returnPolicy: ComposerReturnPolicy {
        didSet { unsettle() }
    }
    /// Called when Return should send the draft.
    public var onSend: (() -> Void)?
    /// Whether the edit menu offers New Line (for a composer whose Return sends).
    public var offersNewLineMenuItem = false
    /// Set by a composer that takes attachments: the edit menu's Paste and
    /// Command-V hand it a copied image or file instead of pasting text (a
    /// plain text view offers no Paste for an image at all). The paste is the
    /// person's own action, so reading the pasteboard then asks nothing.
    public var onPasteAttachments: (() -> Void)?
    /// A downward swipe inside the text, starting at its top, ends editing:
    /// the keyboard goes down and the composer returns to its resting row
    /// (`ComposerSwipeCollapse`), when Settings → Composer → Swipe Down to
    /// Collapse is on (`CmuxMobilePreferences.swipeDownCollapsesComposer`, off
    /// by default). Set false to opt one composer out.
    public var collapsesOnSwipeDown = true
    /// Whether the swipe is on for this view now: its own switch and the setting.
    public var swipeCollapseEnabled: Bool {
        collapsesOnSwipeDown && CmuxMobilePreferences.swipeDownCollapsesComposer()
    }
    /// Called after a swipe down collapsed the composer.
    public var onSwipeCollapse: (() -> Void)?

    private let placeholderLabel = UILabel()
    /// Set while this view inserts its own line break, so the delegate's
    /// Return check lets it through.
    public private(set) var insertingLineBreak = false

    public init(policy: ComposerReturnPolicy) {
        returnPolicy = policy
        super.init(frame: .zero, textContainer: nil)
        isScrollEnabled = true
        alwaysBounceVertical = false
        showsHorizontalScrollIndicator = false
        // A long draft scrolls inside the field with no scroll bar: the
        // field's rounded edge already shows where the text is cut.
        showsVerticalScrollIndicator = false
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .tertiaryLabel
        placeholderLabel.numberOfLines = 1
        placeholderLabel.isAccessibilityElement = false
        addSubview(placeholderLabel)
        swipeCollapse.addTarget(self, action: #selector(swipeCollapseChanged(_:)))
        swipeCollapse.cancelsTouchesInView = false
        swipeCollapse.delegate = swipeCollapseDelegate
        addGestureRecognizer(swipeCollapse)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public var placeholder: String = "" {
        didSet {
            placeholderLabel.text = placeholder
            updatePlaceholder()
        }
    }

    override open var text: String! {
        didSet {
            updatePlaceholder()
            unsettle()
        }
    }

    override open var font: UIFont? {
        didSet { unsettle() }
    }

    override open var textContainerInset: UIEdgeInsets {
        didSet { unsettle() }
    }

    // MARK: Height

    /// The height rule for this view's font, insets and `maxLines`.
    public var fieldHeight: ComposerFieldHeight {
        ComposerFieldHeight(lineHeight: Self.laidOutLineHeight(font ?? .preferredFont(forTextStyle: .body)),
                            verticalInset: textContainerInset.top + textContainerInset.bottom,
                            maxLines: returnPolicy.maxLines)
    }

    /// One line's height as a text view lays it out in `font`. It is taller
    /// than `font.lineHeight` (22 pt against 20.3 for the 17 pt body), so a
    /// maximum computed from the font cut the sixth line in half and
    /// scrolled a draft that fit. Measured once per font.
    private static var lineHeights: [UIFont: CGFloat] = [:]

    private static func laidOutLineHeight(_ font: UIFont) -> CGFloat {
        if let height = lineHeights[font] { return height }
        let probe = UITextView(frame: .zero, textContainer: nil)
        probe.font = font
        probe.textContainerInset = .zero
        probe.textContainer.lineFragmentPadding = 0
        probe.isScrollEnabled = false
        probe.text = "Xg\nXg"
        let two = probe.sizeThatFits(CGSize(width: 1_000, height: CGFloat.greatestFiniteMagnitude)).height
        probe.text = "Xg"
        let one = probe.sizeThatFits(CGSize(width: 1_000, height: CGFloat.greatestFiniteMagnitude)).height
        // The pitch between lines, not the first line's own extent.
        let height = two - one > 0 ? two - one : max(one, font.lineHeight)
        lineHeights[font] = height
        return height
    }

    /// The text's height at `width`, as far as the field's height depends on it: all of a
    /// draft that fits in `maxLines`, else the height of a leading part already taller than
    /// the field (it scrolls, so its height is `maxHeight` whatever follows).
    ///
    /// Constant cost per keystroke in the draft's length: a draft past the field is measured
    /// from its first `measureChunk` units (doubled until they overflow the field), so typing
    /// anywhere after them measures nothing (the same prefix is cached). Measuring the whole
    /// draft on every key laid out all of it, several times per SwiftUI update, one width
    /// per slot: seconds of lag per few keys in a 5,000-character draft on a phone in Low
    /// Power Mode (Leo, 2026-11-23; ComposerTypingLagUITests).
    public func contentHeight(width: CGFloat) -> CGFloat {
        let full = (text ?? "") as NSString
        let width = max(width, 1)
        #if DEBUG
        if Self.measuresWholeDraft {
            // The old rule, for a before/after from one harness: the whole draft, one answer kept.
            let height = measure(full as String, width: width, whole: true)
            measured = measured.filter { $0.key.width == width }
            return height
        }
        #endif
        var limit = Self.measureChunk
        while true {
            if full.length <= limit { return measure(full as String, width: width, whole: true) }
            let cut = full.rangeOfComposedCharacterSequence(at: limit).location
            let height = measure(full.substring(to: cut), width: width, whole: false)
            if fieldHeight.scrolls(contentHeight: height) { return height }
            limit *= 2
        }
    }

    /// UTF-16 units measured first in a long draft: more than the field holds on a
    /// phone (14 lines of ~45 characters); an iPad's wider lines double it once or twice.
    static let measureChunk = 1_024

    /// The height of `text` at `width` in this view's font and insets. `whole`: the view's
    /// own text (measured by the view, as before); else a prefix, measured by a probe
    /// configured the same. SwiftUI's HStack asks for the field's size at several widths in
    /// one pass (none, zero, unbounded, the offered one) and asks again in each pass: one
    /// answer per width stands while text, font and insets are the same. A short ring of
    /// answers visited in turn by more widths than it holds never hit (the gate measured
    /// 45 prefix layouts per key with four slots).
    private func measure(_ text: String, width: CGFloat, whole: Bool) -> CGFloat {
        #if DEBUG
        Self.measureCalls += 1
        #endif
        let key = MeasureKey(text: text, width: width, font: font, inset: textContainerInset,
                             padding: textContainer.lineFragmentPadding)
        if let index = measured.firstIndex(where: { $0.key.width == width }) {
            if measured[index].key == key { return measured[index].height }
            measured.remove(at: index)
        }
        #if DEBUG
        let began = CACurrentMediaTime()
        defer { Self.measureSeconds += CACurrentMediaTime() - began }
        #endif
        let height: CGFloat
        if whole {
            height = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        } else {
            let probe = measureProbe
            probe.font = font
            probe.textContainerInset = textContainerInset
            probe.textContainer.lineFragmentPadding = textContainer.lineFragmentPadding
            probe.text = text
            height = probe.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
        #if DEBUG
        Self.measuredUnits += (text as NSString).length
        #endif
        measured.append((key, height))
        if measured.count > Self.measuredWidths { measured.removeFirst(measured.count - Self.measuredWidths) }
        return height
    }

    private lazy var measureProbe: UITextView = {
        let probe = UITextView(frame: .zero, textContainer: nil)
        probe.isScrollEnabled = isScrollEnabled
        return probe
    }()

    private struct MeasureKey: Equatable {
        var text: String
        var width: CGFloat
        var font: UIFont?
        var inset: UIEdgeInsets
        var padding: CGFloat
    }
    /// One answer per width, the oldest width dropped past this many.
    private static let measuredWidths = 16
    private var measured: [(key: MeasureKey, height: CGFloat)] = []

    /// The field's size for a proposed width (SwiftUI's `sizeThatFits`): as wide as offered,
    /// as tall as `fieldHeight` says for the text at the field's own width.
    ///
    /// The height is settled after each edit (`settleAfterEdit()`) and on a width change, and
    /// answered here as stored, whatever width is proposed: SwiftUI's HStack asks several
    /// widths per pass, and passes repeat, so measuring here measured tens of times per key
    /// (seconds of lag in a 5,000-character draft, Leo 2026-11-23; ComposerTypingLagUITests).
    /// Before the view has a width it measures at the proposed one.
    public func fittingSize(proposedWidth: CGFloat?) -> CGSize {
        let width = proposedWidth ?? (bounds.width > 0 ? bounds.width : 240)
        #if DEBUG
        InputLatencyTrace.shared?.count("size_questions")
        #endif
        #if DEBUG
        if Self.measuresWholeDraft {
            return CGSize(width: width, height: fieldHeight.height(contentHeight: contentHeight(width: width)))
        }
        #endif
        if let settled { return CGSize(width: width, height: settled.height) }
        guard bounds.width > 0 else {
            return CGSize(width: width, height: fieldHeight.height(contentHeight: contentHeight(width: width)))
        }
        return CGSize(width: width, height: settle(width: bounds.width).height)
    }

    /// After the text changed (the delegate's `textViewDidChange`): settles the height for the
    /// new text and asks SwiftUI to size the field again only when the height changed. A key
    /// typed into a draft already past `maxLines` lays out nothing: typing only adds lines,
    /// and the field is at its cap.
    public func settleAfterEdit() {
        let insertedOnly = insertingOnly
        insertingOnly = false
        #if DEBUG
        if Self.measuresWholeDraft { return invalidateIntrinsicContentSize() }
        #endif
        guard let old = settled else { return invalidateIntrinsicContentSize() }
        if insertedOnly, old.scrolls { return }
        if settle(width: old.width).height != old.height { invalidateIntrinsicContentSize() }
    }

    /// The field's height at the field's width: `height`, and whether the text overflows it.
    private var settled: (width: CGFloat, height: CGFloat, scrolls: Bool)?

    /// The text's height as last settled (`contentHeight(width:)` at the field's width): past
    /// `maxLines` a leading part already taller than the field, so clamp against it only. Nil
    /// until the field has a width and a size was asked. For layout that follows the field's
    /// height (an inset, an overlap): read this, never measure per layout pass.
    public private(set) var settledContentHeight: CGFloat?

    /// Something outside the text changed the height rule (a reserve, a strip): measure again
    /// at the field's width, and ask SwiftUI to size the field again if its height changed.
    public func resettle() {
        guard bounds.width > 0 else { return unsettle(invalidate: true) }
        let old = settled?.height
        if settle(width: bounds.width).height != old { invalidateIntrinsicContentSize() }
    }
    /// Set while a typed text goes in at a caret with nothing selected or marked.
    private var insertingOnly = false

    @discardableResult
    private func settle(width: CGFloat) -> (width: CGFloat, height: CGFloat, scrolls: Bool) {
        let rule = fieldHeight
        let content = contentHeight(width: width)
        settledContentHeight = content
        let result = (width: width, height: rule.height(contentHeight: content), scrolls: rule.scrolls(contentHeight: content))
        settled = result
        return result
    }

    /// Text, font, insets or `maxLines` changed: the next size asked for measures again.
    private func unsettle(invalidate: Bool = false) {
        settled = nil
        settledContentHeight = nil
        if invalidate { invalidateIntrinsicContentSize() }
    }

    /// Whether the text now wants another field height than the field has: an edit gained
    /// or lost a line (`ComposerLineMotion`). False before the field is laid out.
    public var lineCountChangePending: Bool {
        guard bounds.width > 0, bounds.height > 0 else { return false }
        return abs(fittingSize(proposedWidth: bounds.width).height - bounds.height) > 0.5
    }

    /// Whether the text is taller than the field (it scrolls inside).
    public var textOverflows: Bool { contentSize.height > bounds.height + 0.5 }

    /// After an edit: a draft taller than the field keeps the caret line in
    /// view; one that fits stays at its top.
    public func followCaret() {
        if !textOverflows {
            pinToTop()
        } else if NSMaxRange(selectedRange) >= (text as NSString? ?? "").length {
            // Typing at the end: the field's bottom inset shows below the last
            // line, as it does at rest (scrollRangeToVisible stops at the
            // caret, leaving the line flush against the field's bottom edge).
            pinToBottom()
        } else {
            scrollRangeToVisible(selectedRange)
        }
    }

    private func pinToBottom() {
        let bottom = max(-adjustedContentInset.top, contentSize.height + adjustedContentInset.bottom - bounds.height)
        if contentOffset.y != bottom { contentOffset.y = bottom }
    }

    private func pinToTop() {
        let top = -adjustedContentInset.top
        if contentOffset.y != top { contentOffset.y = top }
    }

    #if DEBUG
    /// UTF-16 units every composer has laid out to measure its height, so a
    /// test can see what one keystroke costs in text layout
    /// (`<field id>_key_layout_units`, ComposerTypingLagUITests).
    public static var measuredUnits = 0
    /// Height lookups (cached or not) and the widths asked, per key (`_key_measure_calls`).
    public static var measureCalls = 0
    /// Time spent laying out text to measure it (`_key_measure_ms`).
    public static var measureSeconds: CFTimeInterval = 0

    /// `-cmux-mobile-composer-measure-whole`: measure the whole draft on every key with one
    /// answer kept, as before the fix (ComposerTypingLagUITests' before rows).
    /// Composers read the draft in their body while it is on (base's per-key rebuild, too).
    public static let measuresWholeDraft = CommandLine.arguments.contains("-cmux-mobile-composer-measure-whole")

    #endif

    /// A typed text at a bare caret only adds lines (`settleAfterEdit()`).
    override open func insertText(_ text: String) {
        insertingOnly = selectedRange.length == 0 && markedTextRange == nil
        defer { insertingOnly = false }
        #if DEBUG
        if let trace = InputLatencyTrace.shared { return tracedInsert(text, trace: trace) }
        #endif
        super.insertText(text)
    }

    #if DEBUG
    /// A typed key to the frame that draws it (`InputLatencyTrace`:
    /// `<field id>_key_frame`), to its frame committed (`_key_commit`), and
    /// the text it laid out to measure the field (`_key_layout_units`).
    private func tracedInsert(_ text: String, trace: InputLatencyTrace) {
        let id = accessibilityIdentifier ?? "composer"
        let start = CACurrentMediaTime()
        trace.typed()
        let cpu = InputLatencyTrace.threadCPUms()
        let units = Self.measuredUnits
        let calls = Self.measureCalls
        let seconds = Self.measureSeconds
        let counters = trace.counters
        super.insertText(text)
        trace.sampleAtNextFrame("\(id)_key_frame", since: start)
        trace.sampleAfterCommit("\(id)_key_commit", since: start)
        // The main thread's CPU from the key to its frame committed.
        trace.afterCommit { trace.sample("\(id)_key_cpu", ms: InputLatencyTrace.threadCPUms() - cpu) }
        trace.atNextFrame {
            for (name, value) in trace.counters { trace.sample("\(id)_key_\(name)", ms: Double(value - (counters[name] ?? 0))) }
            trace.sample("\(id)_key_layout_units", ms: Double(Self.measuredUnits - units))
            trace.sample("\(id)_key_measure_calls", ms: Double(Self.measureCalls - calls))
            trace.sample("\(id)_key_measure_ms", ms: (Self.measureSeconds - seconds) * 1_000)
        }
    }
    #endif

    override open func layoutSubviews() {
        super.layoutSubviews()
        // A new width (rotation, the send button showing): the height for it.
        if let old = settled, bounds.width > 0, abs(bounds.width - old.width) > 0.5,
           settle(width: bounds.width).height != old.height {
            invalidateIntrinsicContentSize()
        }
        if !textOverflows { pinToTop() }
        let width = max(0, bounds.width - textContainerInset.left - textContainerInset.right)
        let size = placeholderLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        placeholderLabel.frame = CGRect(x: textContainerInset.left + textContainer.lineFragmentPadding, y: textContainerInset.top,
                                        width: width, height: size.height)
    }

    /// Follows a Dynamic Type change.
    public func refreshPlaceholderFont() {
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        setNeedsLayout()
    }

    public func updatePlaceholder() {
        placeholderLabel.isHidden = !(text ?? "").isEmpty
        accessibilityLabel = placeholder
    }

    // MARK: Swipe down to collapse

    private let swipeCollapse = UIPanGestureRecognizer()
    private let swipeCollapseDelegate = SwipeCollapseDelegate()
    private let swipeCollapseRule = ComposerSwipeCollapse()
    /// When the finger came down, and whether the text was at its top then
    /// (read at touch-down: by the pan's `.began` the text's own scroll may
    /// already have moved).
    fileprivate var touchDownTime: TimeInterval = 0
    fileprivate var swipeBeganAtTop = false
    private var swipeHeldFor: TimeInterval = 0

    /// Whether the text shows its first line (a fitting draft always does).
    fileprivate var atTop: Bool { contentOffset.y <= -adjustedContentInset.top + 0.5 }

    @objc private func swipeCollapseChanged(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            swipeHeldFor = touchDownTime > 0 ? max(0, CACurrentMediaTime() - touchDownTime) : 0
        case .changed, .ended:
            guard swipeCollapseEnabled, isFirstResponder,
                  swipeCollapseRule.collapses(translation: pan.translation(in: self), velocity: pan.velocity(in: self),
                                              beganAtTop: swipeBeganAtTop, heldFor: swipeHeldFor) else { return }
            // Stop this drag so it collapses once.
            pan.isEnabled = false
            pan.isEnabled = true
            resignFirstResponder()
            onSwipeCollapse?()
        default:
            break
        }
    }

    /// Lets the swipe run beside the text view's own scroll, selection and
    /// loupe gestures (a separate object: a UIScrollView subclass must not
    /// become a recognizer delegate itself).
    private final class SwipeCollapseDelegate: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// The finger came down (touch timestamps share `CACurrentMediaTime`'s clock).
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if let view = gestureRecognizer.view as? ComposerReturnTextView {
                view.touchDownTime = touch.timestamp
                view.swipeBeganAtTop = view.atTop
            }
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let view = gestureRecognizer.view as? ComposerReturnTextView else { return false }
            return view.swipeCollapseEnabled && view.isFirstResponder
        }
    }

    // MARK: Return

    /// Asked by the delegate for a "\n" replacement (the on-screen keyboard's
    /// Return, or a hardware Return no key command took): true inserts it,
    /// false means it sent (or was refused).
    public func returnShouldInsert(_ replacement: String) -> Bool {
        guard replacement == "\n", !insertingLineBreak else { return true }
        switch returnPolicy.action(hardware: false) {
        case .newline:
            return true
        case .send:
            onSend?()
            return false
        }
    }

    /// Inserts a line break at the selection (Shift-Return, New Line).
    public func insertLineBreak() {
        insertingLineBreak = true
        defer { insertingLineBreak = false }
        insertText("\n")
        followCaret()
    }

    @objc private func hardwareReturn() { perform(returnPolicy.action(hardware: true)) }
    @objc private func hardwareShiftReturn() { perform(returnPolicy.action(hardware: true, shift: true)) }
    @objc private func hardwareOptionReturn() { perform(returnPolicy.action(hardware: true, option: true)) }

    private func perform(_ action: ComposerReturnAction) {
        switch action {
        case .newline: insertLineBreak()
        case .send: onSend?()
        }
    }

    override open var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + returnCommands
    }

    /// Built once: UIKit reads `keyCommands` as the field becomes first
    /// responder, before the keyboard's first frame.
    private lazy var returnCommands: [UIKeyCommand] = {
        let commands = [
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(hardwareReturn)),
            UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(hardwareShiftReturn)),
            UIKeyCommand(input: "\r", modifierFlags: .alternate, action: #selector(hardwareOptionReturn)),
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }()

    override open func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(hardwareReturn), #selector(hardwareShiftReturn), #selector(hardwareOptionReturn):
            // Composing text: Return commits the candidate (the input method's).
            return isEditable && markedTextRange == nil
        case #selector(paste(_:)) where pastesAttachments:
            return isEditable
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    // MARK: Paste

    /// An image or a copied file leads the pasteboard, for a composer that
    /// takes attachments (`composerPastesAttachments`).
    private var pastesAttachments: Bool {
        guard onPasteAttachments != nil else { return false }
        // UIKit validates Paste as the field becomes first responder, before
        // the keyboard's first frame; reading the pasteboard's types costs
        // about 0.4 ms. Read them again only once the pasteboard changed.
        let pasteboard = UIPasteboard.general
        let change = pasteboard.changeCount
        if let pasteCheck, pasteCheck.change == change { return pasteCheck.attaches }
        let attaches = pasteboard.composerPastesAttachments
        pasteCheck = (change, attaches)
        return attaches
    }

    private var pasteCheck: (change: Int, attaches: Bool)?

    override open func paste(_ sender: Any?) {
        if pastesAttachments, let onPasteAttachments {
            onPasteAttachments()
        } else {
            super.paste(sender)
        }
    }

    override open func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard offersNewLineMenuItem, isEditable else { return }
        let newLine = UIAction(title: String(localized: "New Line"), image: UIImage(systemName: "return")) { [weak self] _ in
            self?.insertLineBreak()
        }
        builder.insertChild(UIMenu(options: .displayInline, children: [newLine]), atStartOfMenu: .standardEdit)
    }
}
#endif
