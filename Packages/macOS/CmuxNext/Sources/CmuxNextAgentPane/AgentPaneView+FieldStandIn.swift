public import AppKit
import CmuxNextDesign

/// What a New Tab field stand-in hands the page's field (``NewTabFieldStandIn``).
public nonisolated struct NewTabFieldSeed: Sendable, Equatable, Encodable {
    public var text: String
    /// The selection, in UTF-16 offsets of `text` (the page's `setSelectionRange` units).
    public var selectionStart: Int
    public var selectionEnd: Int
    /// Return was pressed in the stand-in: the page sends once it took the text.
    public var submit: Bool

    public init(text: String, selectionStart: Int, selectionEnd: Int, submit: Bool) {
        (self.text, self.selectionStart, self.selectionEnd, self.submit) = (text, selectionStart, selectionEnd, submit)
    }

    /// Nothing was typed into the stand-in: the page keeps what its field shows (and stays untouched).
    public var isEmpty: Bool { text.isEmpty && !submit }
}

/// The native field a cold New Tab page's pane shows until the page's own field exists (hold-class rule: no key waits
/// for a field that does not exist yet). It takes the person's keys in the open's own frame, with the system's
/// editing, selection and input methods, and hands its text, selection and Return to the page's field once
/// (``seed()``, ``AgentPaneView/receiveFieldSeed(_:)``). No key event is replayed.
public final class NewTabFieldStandIn: NSTextView {
    /// Return pressed: the page sends after it took the text. Later keys still edit until the hand-off.
    public private(set) var submitted = false

    public convenience init() {
        self.init(frame: .zero)
        font = Typography.body
        isRichText = false
        isFieldEditor = true
        // No fill: it draws over the pane's own background until the page shows. Never an undo target: it lives until
        // the page's field takes its text, a few hundred milliseconds.
        drawsBackground = false
        textContainerInset = NSSize(width: 10, height: 7)
        textContainer?.maximumNumberOfLines = 1
        textContainer?.lineBreakMode = .byClipping
        textContainer?.widthTracksTextView = true
        isHorizontallyResizable = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        setAccessibilityRole(.textField)
        setAccessibilityLabel(String(localized: "newTab.standIn.label", defaultValue: "Search or type a command",
                                     bundle: .module, comment: "Accessibility label of the New Tab field shown while its page loads"))
        paintBorder()
    }

    override public func insertNewline(_ sender: Any?) { submitted = true }
    /// Escape and Option-Escape do what they do in the page's field before it exists: nothing (no completion popup).
    override public func cancelOperation(_ sender: Any?) {}
    override public func complete(_ sender: Any?) {}

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paintBorder()
    }

    private func paintBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [layer] in layer?.borderColor = NSColor.separatorColor.cgColor }
    }

    /// The text and selection to hand over; an input method's marked text is committed first.
    public func seed() -> NewTabFieldSeed {
        if hasMarkedText() { unmarkText() }
        let range = selectedRange()
        return NewTabFieldSeed(text: string, selectionStart: range.location, selectionEnd: range.location + range.length,
                               submit: submitted)
    }

    /// Where the page's field will sit in a pane whose content fills `content` (the New Tab composer, centered, in the
    /// upper part): at most 640 points wide, one line high. `flipped`: the pane's view counts y from the top.
    public static func frame(in content: NSRect, flipped: Bool) -> NSRect {
        let width = min(640, max(120, content.width - 64)), height: CGFloat = 32
        let fromTop = (content.height * 0.38).rounded()
        let y = flipped ? content.minY + fromTop : content.maxY - fromTop - height
        return NSRect(x: (content.midX - width / 2).rounded(), y: y, width: width, height: height)
    }
}

extension AgentPaneView {
    /// A New Tab stand-in field's text for this page's field (``NewTabFieldStandIn``): given once; an empty seed
    /// changes nothing.
    public func receiveFieldSeed(_ seed: NewTabFieldSeed) {
        guard !seed.isEmpty else { return }
        if let fieldSeedSink { return fieldSeedSink(seed) }
        guard let data = try? JSONEncoder().encode(seed), let json = String(data: data, encoding: .utf8) else { return }
        evaluateScript("window.dispatchEvent(new CustomEvent('acpmux-newtab-seed', {detail: \(json)}))")
    }

    /// Runs `body` once the page has drawn its first frame (now if it has).
    public func whenPagePainted(_ body: @escaping () -> Void) { model.whenPainted(body) }

    /// Whether the page has drawn its first frame.
    public var pageHasPainted: Bool { model.hasPainted }
}
