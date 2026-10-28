public import AppKit
import CmuxNextDesign

/// What a New Tab field stand-in hands the page's field (``AgentPaneView/showFieldStandIn()``).
public nonisolated struct NewTabFieldSeed: Sendable, Equatable, Encodable {
    public var text: String
    /// The selection, in UTF-16 offsets of `text` (the page's `setSelectionRange` units).
    public var selectionStart: Int
    public var selectionEnd: Int
    /// Return was pressed in the stand-in: the page submits once it took the text.
    public var submit: Bool

    public init(text: String, selectionStart: Int, selectionEnd: Int, submit: Bool) {
        (self.text, self.selectionStart, self.selectionEnd, self.submit) = (text, selectionStart, selectionEnd, submit)
    }
}

/// The native field a cold New Tab page shows over its loading cover (hold-class rule: no key waits for a field that
/// does not exist yet). It takes the person's keys in the open's own frame, with the system's editing, selection and
/// input methods; when the page's field takes focus it hands over its text and selection once (an input method's
/// marked text is committed first) and goes. No key event is replayed.
final class NewTabFieldStandIn: NSTextView {
    /// Return pressed: the page submits after it took the text. Later keys still edit until the handoff.
    private(set) var submitted = false

    convenience init() {
        self.init(frame: .zero)
        font = Typography.body
        isRichText = false
        isFieldEditor = true
        // No fill: it draws over the page's own background (the loading cover). No undo: it lives until the page's
        // field takes its text, a few hundred milliseconds.
        drawsBackground = false
        textContainerInset = NSSize(width: 10, height: 7)
        textContainer?.maximumNumberOfLines = 1
        textContainer?.lineBreakMode = .byClipping
        textContainer?.widthTracksTextView = true
        isHorizontallyResizable = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        setAccessibilityRole(.textField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    override func insertNewline(_ sender: Any?) { submitted = true }

    /// The text and selection to hand over; an input method's marked text is committed first.
    func seed() -> NewTabFieldSeed {
        if hasMarkedText() { unmarkText() }
        let range = selectedRange()
        return NewTabFieldSeed(text: string, selectionStart: range.location, selectionEnd: range.location + range.length,
                               submit: submitted)
    }
}

extension AgentPaneView {
    /// The stand-in now shown, nil when none.
    public var fieldStandIn: NSView? { standInField }

    /// A cold New Tab page (it has not painted; its field does not exist yet) in a window: shows the native stand-in
    /// field where the page's field will be, gives it the keyboard, and returns it. When the page's field takes focus,
    /// the stand-in hands it its text and selection and goes. Nil for a page that painted or is no New Tab page (its
    /// own field takes the keys).
    @discardableResult
    public func showFieldStandIn() -> NSView? {
        if let standInField { return standInField }
        guard model.newTab != nil, !model.hasPainted, !inputReadiness.isEditableFocused, let window else { return nil }
        let field = NewTabFieldStandIn()
        field.frame = Self.standInFrame(in: topBar.contentFrame(in: bounds))
        field.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        addSubview(field, positioned: .above, relativeTo: nil)
        standInField = field
        window.makeFirstResponder(field)
        inputReadiness.whenEditableFocused { [weak self] in self?.handOffFieldStandIn() }
        return field
    }

    /// The page's field took focus: one transfer of the stand-in's text, selection and Return, then it goes.
    func handOffFieldStandIn() {
        guard let field = standInField else { return }
        let seed = field.seed()
        standInField = nil
        let hadKeyboard = field.window?.firstResponder === field
        field.removeFromSuperview()
        if let fieldSeedSink {
            fieldSeedSink(seed)
        } else if let data = try? JSONEncoder().encode(seed), let json = String(data: data, encoding: .utf8) {
            evaluateScript("window.dispatchEvent(new CustomEvent('acpmux-newtab-seed', {detail: \(json)}))")
        }
        if hadKeyboard { focusChat() }
    }

    /// The page's field sits centered in the upper part of the page (the New Tab composer); the stand-in takes its
    /// place: at most 640 points wide, one line high.
    static func standInFrame(in content: NSRect) -> NSRect {
        let width = min(640, max(120, content.width - 64)), height: CGFloat = 32
        return NSRect(x: (content.midX - width / 2).rounded(), y: (content.minY + content.height * 0.38).rounded(),
                      width: width, height: height)
    }
}
