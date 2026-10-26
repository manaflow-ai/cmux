#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its text input.
public import AppKit

/// The page's `NSTextInputClient` in host mode
/// (plans/cmux-next/chrome-parity/p01-process.md 3.3, task 043): input
/// methods, dead keys, the emoji picker and dictation talk to this view, as
/// they talk to Chrome's `RenderWidgetHostViewCocoa`
/// (content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm), whose
/// rules ``ChromiumHostTextInput`` keeps. What the input method changes goes
/// to the host as ops on the ordered stream (``textInputSink``); what it asks
/// (selection, marked range, text, character rects) is answered from the
/// state the host pushed ahead (``applyTextInputState(_:)``). No method here
/// sends and waits: Chrome's two sync calls (`SyncGetFirstRectForRange`,
/// `SyncGetCharacterIndexAtPoint`) have no counterpart.
extension ChromiumHostPageView: NSTextInputClient {
    // MARK: Turns

    /// A key down: the input method sees it first, then the key goes to the
    /// host as its calls decided (a plain key, a process key and a
    /// composition, a commit).
    ///
    /// - Returns: Where the writer put the frame that carries the key itself
    ///   (a plain key down), nil when no frame does or the writer stamped none.
    func textInputKeyDown(_ event: NSEvent, key: ChromiumHostFrame) -> ChromiumHostInputReceipt? { // perf-hot: 1ms cef-host-input (every key typed into a hosted page)
        textInput.beginKey()
        interpretKeyEvents([event])
        let controlOrCommand = !event.modifierFlags.isDisjoint(with: [.control, .command])
        return deliver(textInput.endKey(key, controlOrCommand: controlOrCommand))
    }

    /// Takes the host's TEXT_INPUT_STATE push (task 044).
    func applyTextInputState(_ state: ChromiumHostTextInputState) {
        // The context before the push: a push with no field focused takes it away.
        let context = inputContext
        let applied = textInput.apply(state)
        if applied.discardMarkedText { context?.discardMarkedText() }
        if applied.invalidateCharacterCoordinates { context?.invalidateCharacterCoordinates() }
    }

    /// A mouse down while composing, before the down goes to the page: the
    /// composition ends with its text kept and the input method drops its
    /// marked text, so the caret never moves with a composition open. The
    /// click is not offered to the input method: Chrome's
    /// `-[RenderWidgetHostViewCocoa mouseEvent:]` calls `finishComposingText`
    /// and sends the down.
    func textInputMouseDown() {
        guard textInput.hasMarkedText else { return }
        let context = inputContext
        let outputs = textInput.finishComposition()
        context?.discardMarkedText()
        deliver(outputs)
    }

    /// The page lost focus: the page ends its own composition on blur, so the
    /// input method drops its marked text and nothing goes to the host
    /// (Chrome's `cancelComposition` from `resignFirstResponder`).
    func textInputDidResign() {
        let context = inputContext
        if textInput.cancelComposition() { context?.discardMarkedText() }
    }

    /// Sends `outputs` in order. Returns the receipt of the plain key down among them.
    @discardableResult
    private func deliver(_ outputs: [ChromiumHostTextInput.Output]) -> ChromiumHostInputReceipt? {
        var carried: ChromiumHostInputReceipt?
        for output in outputs {
            switch output {
            case .key(let frame):
                let receipt = sink?(frame)
                if frame.v[0] == 0, frame.v[3] == ChromiumHostTextInput.KeyMark.plain.rawValue { carried = receipt }
            case .op(let op):
                textInputSink?(op)
            }
        }
        return carried
    }

    /// None while no field can take an input method (no text field focused,
    /// a password field): key bindings still type there.
    public override var inputContext: NSTextInputContext? {
        textInput.state.type.takesInputMethod ? super.inputContext : nil
    }

    // MARK: NSTextInputClient: changes

    public func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = Self.plainText(string) else { return }
        deliver(textInput.insertText(text, replacement: Self.range(replacementRange)))
    }

    /// With no input context (no field, a password field) AppKit's key
    /// bindings call NSResponder's one-argument form (Chrome forwards it the same way).
    public override func insertText(_ insertString: Any) {
        insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let text = Self.plainText(string) else { return }
        let length = text.utf16.count
        let clauses = (string as? NSAttributedString).map(ChromiumHostCompositionClause.clauses(of:))
            ?? [ChromiumHostCompositionClause(range: 0..<length, thick: false)]
        let selection = Self.range(selectedRange) ?? length..<length
        deliver(textInput.setMarkedText(text, clauses: clauses, selection: selection,
                                        replacement: Self.range(replacementRange)))
    }

    public func unmarkText() {
        deliver(textInput.unmarkText())
    }

    public override func doCommand(by selector: Selector) {
        deliver(textInput.doCommand(NSStringFromSelector(selector)))
    }

    /// Chrome's set: the underlines an input method marks clauses with. AppKit declares
    /// `NSTextInputReplacementRangeAttributeName` as a plain string, so it imports as a global, not a key member.
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .underlineColor, .markedClauseSegment, NSAttributedString.Key(NSTextInputReplacementRangeAttributeName)]
    }

    // MARK: NSTextInputClient: questions, from pushed state only

    public func hasMarkedText() -> Bool {
        textInput.hasMarkedText
    }

    public func markedRange() -> NSRange {
        Self.nsRange(textInput.markedRange)
    }

    public func selectedRange() -> NSRange {
        Self.nsRange(textInput.state.selection)
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        // SAFETY: AppKit's out-parameter, an NSRange it owns for this call (NSTextInputClient); NULL is skipped.
        unsafe actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
        guard let requested = Self.range(range), let found = textInput.substring(of: requested) else { return nil }
        // SAFETY: as above.
        unsafe actualRange?.pointee = Self.nsRange(found.actual)
        return NSAttributedString(string: found.text)
    }

    /// The rect in screen points (where the candidate window and the
    /// dictation indicator go).
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let requested = Self.range(range) ?? (textInput.state.selection ?? 0..<0)
        let found = textInput.firstRect(for: requested)
        // SAFETY: AppKit's out-parameter, an NSRange it owns for this call (NSTextInputClient); NULL is skipped.
        unsafe actualRange?.pointee = Self.nsRange(found.actual)
        let page = found.rect
        // Page points have a top-left origin; this view's are bottom-left.
        let local = NSRect(x: page.minX, y: bounds.height - page.maxY, width: page.width, height: page.height)
        let inWindow = convert(local, to: nil)
        return window?.convertToScreen(inWindow) ?? inWindow
    }

    public func characterIndex(for point: NSPoint) -> Int {
        guard let window else { return NSNotFound }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        return textInput.characterIndex(at: CGPoint(x: local.x, y: bounds.height - local.y)) ?? NSNotFound
    }

    // MARK: Conversions

    private static func plainText(_ string: Any) -> String? {
        switch string {
        case let attributed as NSAttributedString: attributed.string
        case let plain as String: plain
        default: nil
        }
    }

    /// A range an input method passed; nil for NSNotFound or one that does not fit.
    static func range(_ range: NSRange) -> Range<Int>? {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= Int.max - range.length else { return nil }
        return range.location..<(range.location + range.length)
    }

    static func nsRange(_ range: Range<Int>?) -> NSRange {
        guard let range else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: range.lowerBound, length: range.count)
    }
}

extension ChromiumHostCompositionClause {
    /// The clauses an input method marked with underlines, thick for the
    /// selected one (Chrome's `ExtractUnderlines`).
    static func clauses(of string: NSAttributedString) -> [ChromiumHostCompositionClause] {
        var clauses: [ChromiumHostCompositionClause] = []
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attributes, range, _ in
            guard let style = attributes[.underlineStyle] as? NSNumber else { return }
            var clause = ChromiumHostCompositionClause(range: range.location..<NSMaxRange(range), thick: style.intValue > 1)
            if let color = (attributes[.underlineColor] as? NSColor)?.usingColorSpace(.sRGB) {
                clause.color = argb(color)
            }
            clauses.append(clause)
        }
        return clauses
    }

    private static func argb(_ color: NSColor) -> UInt32 {
        func byte(_ component: CGFloat) -> UInt32 { UInt32((min(max(component, 0), 1) * 255).rounded()) }
        return byte(color.alphaComponent) << 24 | byte(color.redComponent) << 16 | byte(color.greenComponent) << 8
            | byte(color.blueComponent)
    }
}
#endif
