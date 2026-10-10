import AppKit

/// The compose field's NSTextView: Return sends, Option/Shift+Return adds a
/// newline, Esc cancels, and pasted images become attachments (Catalyst's
/// `ComposeTextView` key commands). IME marked text, the caret and selection
/// are AppKit's own.
final class FieldTextView: NSTextView {
    var onSend: () -> Void = {}
    var onEscape: () -> Void = {}
    var onPasteImage: (NSImage) -> Void = { _ in }
    /// cmux: the host's attachment intake reads the pasteboard first
    /// (files and pictures, Home's type rule); true when it took the paste.
    var onPastePasteboard: (NSPasteboard) -> Bool = { _ in false }
    /// Marked (IME) text changed. UITextView reports marked text through
    /// `textViewDidChange`, so the draft (and the field height) follows the
    /// composition; NSTextView does not post a text change for it.
    var onMarkedTextChange: () -> Void = {}
    /// A press in the field (before the text view tracks it): the field glass's press light.
    var onPress: (NSEvent) -> Void = { _ in }
    /// The release of that press (the mouse-up that ended the text view's tracking).
    var onRelease: (NSEvent) -> Void = { _ in }
    override func mouseDown(with event: NSEvent) {
        onPress(event)
        super.mouseDown(with: event)
        if let up = NSApp.currentEvent, up.type == .leftMouseUp { onRelease(up) }
    }

    /// The inset above the first line (UITextView's 6.24 pt). `textContainerInset.height` is half of
    /// the top and bottom insets together (AppKit adds it above and below the text when it sizes
    /// the document); this origin puts the text at the top inset as given: AppKit rounds the
    /// container origin to whole points, which put the text 0.24 pt higher than Catalyst's
    /// (measured by the text probe's first baseline).
    var textTopInset: CGFloat = 0
    override var textContainerOrigin: NSPoint { NSPoint(x: textContainerInset.width, y: textTopInset) }

    /// The caret's NSTextInsertionIndicator shows no effects view. Its
    /// glass bubble (input source, dictation, caps lock) sits just left of the
    /// caret, which is 7 pt into the field, so it covered the "+" glass. The
    /// text view adds (and rebuilds) its indicators as subviews.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? NSTextInsertionIndicator)?.automaticModeOptions.remove(.showEffectsView)
    }
    /// The layer's scale is the scale of the window it draws into, or `DisplayScale.current` when
    /// it has no window (the offscreen harness and captures). AppKit sets it again on each backing
    /// change and window move, so this runs after AppKit does (and from `ComposeView.rescale`).
    func applyScale() {
        let s = window?.backingScaleFactor ?? DisplayScale.current
        if let l = layer, l.contentsScale != s { l.contentsScale = s }
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); applyScale() }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedTextChange()
    }

    override func keyDown(with event: NSEvent) {
        // Marked text (IME composition) owns Return and Esc.
        if hasMarkedText() { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 || event.keyCode == 76 {
            if flags.contains(.option) || flags.contains(.shift) { insertText("\n", replacementRange: selectedRange()); return }
            onSend(); return
        }
        if event.keyCode == 53 { onEscape(); return }
        super.keyDown(with: event)
    }

    // MARK: Caret (UIKit's, as Messages draws it)

    /// Messages' caret is UIKit's, not AppKit's insertion indicator (lossless references,
    /// macOS 27): it shows at once when the field takes focus or the caret moves (AppKit's
    /// fades in over 0.15 s), stays solid 0.56 s, then blinks with a 1.0 s period in four
    /// steps of 25 % about 35 ms apart (out at +0.56, in at +0.90); it is 1 x 17 pt, 0.5 pt
    /// left of and 1.25 pt below AppKit's 1 x 16 pt one. AppKit's blink has the same period,
    /// so only the reset, the fade-in and the geometry differ; this layer replaces it.
    private let caretView = CaretView()
    /// A plain sublayer of the caret view's layer (AppKit manages the view's own layer).
    let caretLayer = CALayer()
    /// Off: AppKit's own indicator (`--appkit-caret`, and capture mode, which draws its own).
    static let ownCaret = !ProcessInfo.processInfo.arguments.contains("--appkit-caret")
    /// `--caret-log`: caret placements and blink restarts to /tmp/caret.log (diagnostics).
    static let caretLog = ProcessInfo.processInfo.arguments.contains("--caret-log")
    static func log(_ s: String) {
        let url = URL(fileURLWithPath: "/tmp/caret.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data((s + "\n").utf8)); try? h.close() }
        else { try? Data((s + "\n").utf8).write(to: url) }
    }
    var caretSuspended = false { didSet { updateCaret(reset: false) } }

    func installCaret() {
        guard Self.ownCaret else { return }
        insertionPointColor = .clear
        caretView.wantsLayer = true
        caretView.layer?.addSublayer(caretLayer)
        caretLayer.frame = CGRect(x: 0, y: 0, width: 1, height: 17)
        caretLayer.backgroundColor = Fixture.caret.cgColor
        caretLayer.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "opacity": NSNull()]
        caretView.isHidden = true
    }

    /// The field's clip (`ComposeTextView.clip`: the text view is the document of its scroll view).
    private var fieldClip: NSView? { enclosingScrollView?.superview }

    /// Places the caret and, with `reset`, restarts its blink (solid first).
    func updateCaret(reset: Bool = true) {
        let anchor: NSView = fieldClip ?? self
        guard Self.ownCaret, let window, let host = anchor.superview else { caretView.isHidden = true; return }
        // A sibling view above the field's clip (Messages' caret starts 0.5 pt left of the text,
        // outside the clip).
        if caretView.superview !== host { host.addSubview(caretView, positioned: .above, relativeTo: anchor) }
        let sel = selectedRange()
        var show = !caretSuspended && window.isKeyWindow && window.firstResponder === self && sel.length == 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var caretFrame = CGRect.zero
        if show {
            let screen = firstRect(forCharacterRange: NSRange(location: sel.location, length: 0), actualRange: nil)
            let r = convert(window.convertFromScreen(screen), from: nil)
            caretFrame = convert(CGRect(x: r.minX + Self.caretDX, y: r.midY + Self.caretDY, width: 1, height: 17), to: host)
            // A caret line scrolled out of the field (past `ComposeView.maxLines`) hides the caret,
            // as UIKit's in Messages' field.
            if let clip = fieldClip {
                let v = clip.convert(clip.bounds, to: host)
                show = caretFrame.midY >= v.minY && caretFrame.midY <= v.maxY
            }
            if Self.caretLog { Self.log("line \(r) caret \(caretFrame) shown \(show) reset \(reset)") }
        }
        guard show else { caretView.isHidden = true; caretLayer.removeAllAnimations(); return }
        caretView.frame = caretFrame
        let wasHidden = caretView.isHidden
        caretView.isHidden = false
        if reset || wasHidden || caretLayer.animation(forKey: "blink") == nil { startBlink() }
    }

    /// Caret geometry against the line rect AppKit reports (fitted on swipe-partial and
    /// field-focus-type: Messages' caret 62.5-63.5 x 1007-1024 pt in the one-line field).
    static let caretDX: CGFloat = -0.5, caretDY: CGFloat = -8.5 + 1.75

    /// Solid time after a reset (references: 0.55 s in reply-menu-send, 0.58 s in field-focus-type).
    static let caretSolid: CFTimeInterval = 0.56

    private func startBlink() {
        if Self.caretLog { Self.log("blink restart \(CACurrentMediaTime())") }
        caretLayer.removeAnimation(forKey: "blink")
        caretLayer.opacity = 1
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.calculationMode = .discrete
        // One period from the first fade-out: out 1 -> 0 in four steps, off, in 0 -> 1.
        // Discrete: one more key time than values (each value holds until the next key time).
        a.values = [0.75, 0.5, 0.25, 0, 0.25, 0.5, 0.75, 1]
        a.keyTimes = [0, 0.035, 0.07, 0.105, 0.34, 0.375, 0.41, 0.445, 1]
        a.duration = 1.0
        a.repeatCount = .infinity
        // Solid (the model value 1) until the blink begins, then it repeats.
        a.beginTime = caretLayer.convertTime(CACurrentMediaTime(), from: nil) + Self.caretSolid
        a.isRemovedOnCompletion = false
        caretLayer.add(a, forKey: "blink")
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        updateCaret()
        if !stillSelecting, !DeferredSpellChecker.useAppKit { spell.selectionDidChange() }
    }
    override func didChangeText() {
        super.didChangeText()
        updateCaret()
        if !DeferredSpellChecker.useAppKit { spell.textDidChange() }
    }

    /// Spell checking while typing, off the keystroke frame (SpellCheck.swift); the Edit
    /// menu's "Check Spelling While Typing" switches it.
    lazy var spell = DeferredSpellChecker(view: self)
    override func toggleContinuousSpellChecking(_ sender: Any?) {
        if DeferredSpellChecker.useAppKit { super.toggleContinuousSpellChecking(sender) } else { spell.enabled.toggle() }
    }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if !DeferredSpellChecker.useAppKit, item.action == #selector(toggleContinuousSpellChecking(_:)) {
            (item as? NSMenuItem)?.state = spell.enabled ? .on : .off
            return true
        }
        return super.validateUserInterfaceItem(item)
    }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.updateCaret() }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.updateCaret(reset: false) }
        return ok
    }
    // cmux: block observers on queue: .main (inline for AppKit's post on main), not selectors:
    // a selector into this main-actor view trapped on a post off main (crash program).
    private var keyObservers: [NSObjectProtocol] = []
    deinit { keyObservers.forEach { NotificationCenter.default.removeObserver($0) } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyScale()
        let nc = NotificationCenter.default
        keyObservers.forEach { nc.removeObserver($0) }  // cmux
        keyObservers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {  // cmux
            keyObservers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.updateCaret() })
        }
    }
    override func setFrameSize(_ newSize: NSSize) {
        let heightChanged = newSize.height != frame.height
        super.setFrameSize(newSize)
        // The document's height changed (an edit, or a rewrap at a new width): the caret line stays
        // in view, as in Messages' field. (A narrowing rewrapped the lines after the clip's
        // scroll: the last line stayed under the field.)
        if heightChanged { keepCaretInView() }
        updateCaret(reset: false)
    }
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        keepCaretInView()
    }
    /// Scrolls the caret's line into the field (the clip of `ComposeTextView`), when the field scrolls.
    func keepCaretInView() {
        guard let sv = enclosingScrollView, frame.height > sv.contentSize.height + 0.5 else { return }
        scrollRangeToVisible(selectedRange())
    }

    /// The pasteboard Paste reads (a check injects its own).
    var pasteboard: NSPasteboard = .general

    override func paste(_ sender: Any?) {
        let pb = pasteboard
        if onPastePasteboard(pb) { return }  // cmux
        if pb.string(forType: .string) == nil, let img = NSImage(pasteboard: pb) { onPasteImage(img); return }
        super.paste(sender)
    }
}

/// The caret's view: drawn only, never hit (clicks at the caret reach the text view).
final class CaretView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The field's clip: a flipped view whose layer the field's growth animates (its top on the field
/// top, its height revealing the new line, as UITextView's frame on Catalyst).
final class FieldClipView: NSView {
    override var isFlipped: Bool { true }
}

/// `compose.textView` for the shared window view: the NSTextView, the scroll view it is the
/// document of, and the clip around them (the shared code removes animations from its layer).
/// Messages' field is a UITextView, a scroll view: past `ComposeView.maxLines` its text scrolls and
/// keeps the caret line in view. Here AppKit does the same: the NSTextView scrolls its insertion
/// point into view in its clip view after every edit and caret move.
final class ComposeTextView {
    let view: FieldTextView
    let scrollView = NSScrollView()
    let clip = FieldClipView()
    // init sets the clip's wantsLayer, so the layer exists; a detached layer stands in otherwise.
    var layer: CALayer { clip.layer ?? CALayer() }
    var onSend: () -> Void { get { view.onSend } set { view.onSend = newValue } }
    var onEscape: () -> Void { get { view.onEscape } set { view.onEscape = newValue } }
    var text: String { view.string }
    private var scrolled: NSObjectProtocol?
    init() {
        // TextKit 2, as UITextView on Catalyst.
        view = FieldTextView(usingTextLayoutManager: true)
        view.wantsLayer = true
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = ComposeView.showsScroller
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .automatic
        scrollView.horizontalScrollElasticity = .none
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = view
        clip.addSubview(scrollView)
        // The caret follows the text when the field scrolls (a trackpad scroll over the field).
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrolled = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: nil) { [weak view] _ in
            view?.updateCaret(reset: false)
        }
    }
    deinit { scrolled.map(NotificationCenter.default.removeObserver) }
    func insertText(_ s: String) { view.insertText(s, replacementRange: view.selectedRange()) }

    /// The clip at FRAME (host coordinates): the document is at least the clip's height, as wide
    /// as it; a size change keeps the caret line in view (a live resize rewraps the lines).
    func place(_ frame: CGRect) {
        guard clip.frame != frame else { return }
        let rewrap = clip.frame.width != frame.width
        clip.frame = frame
        let size = scrollView.contentSize
        view.minSize = NSSize(width: 0, height: size.height)
        if view.frame.width != size.width { view.setFrameSize(NSSize(width: size.width, height: view.frame.height)) }
        // A new width rewraps the lines: TextKit lays them out again lazily, after this scroll.
        // Laid out now, the document's height and the caret's line are the new ones when the
        // caret is scrolled into view (the last line stayed under the field after a narrowing).
        if rewrap, let tlm = view.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
        view.sizeToFit()
        view.keepCaretInView()
    }
}

/// Compose bar: "+" and emoji buttons, and the field with a real NSTextView.
/// Layers, geometry and springs are catalyst's current ComposeView
/// (catalyst/Sources/Compose.swift: fill, rim, veil and tint over a flying
/// bubble, the overlay that the window view puts above the morph), so
/// captures and the differential harness match it. In a live window
/// (`nativeChrome`) the drawn glass, rim, veil and buttons are hidden (the tint stays):
/// AppKit's NSGlassEffectView field and glass buttons are there instead
/// (Host.swift), above the morph, and `onFieldResize` hands every field
/// height change to the window so the glass view's layer gets the same
/// render-server springs.
final class ComposeView: UIView {
    let textView = ComposeTextView()
    private let buttons = CanvasView()
    let glass = CALayer()
    private let placeholderLayer = CALayer()
    private let waveLayer = CALayer()
    /// What Messages draws above a bubble that flies out of the field (the
    /// window view moves it above its morph layer).
    let overlay = CALayer()
    static let overlayName = "composeGlassOverlay"
    private let veil = CALayer()
    private let tint = CALayer()
    private let rim = CALayer()
    static let rimFadeDepth = 0.45
    /// Attachments: images as the image, files as pills (shared, ComposeAttachments.swift).
    let strip = ComposeAttachmentStrip()
    private var chipsLayer: CALayer { strip.layer }
    /// Catalyst's plus UIButton's layer (empty; keeps the layer order).
    private let plusLayer = CALayer()
    /// Capture mode draws its own caret (the text view's blinks on its own timer).
    let caret = CALayer()
    /// Capture mode: the text view's drawing, placed where the text view is
    /// (the NSTextView is not in the layer tree that captures render).
    let textSnapshot = CALayer()
    private(set) var fieldHeight: CGFloat = ComposeMetrics.oneLine
    private(set) var chips: [Attachment] = []
    private(set) var text = ""
    private var placeholder = Strings.placeholder
    var captureMode = false {
        didSet {
            caret.isHidden = !captureMode
            textSnapshot.isHidden = !captureMode
            textView.view.insertionPointColor = captureMode || FieldTextView.ownCaret ? .clear : Fixture.caret
            textView.view.caretSuspended = captureMode
        }
    }
    var onRemoveChip: (ID) -> Void = { _ in }
    /// Live window: AppKit materials replace the drawn glass and buttons.
    var nativeChrome = false {
        didSet {
            // The tint stays: AppKit's glass does not dim a bubble still inside the field after
            // the send fade, real Messages does (lossless send-typed-take1, 108 ms: blue 208 above
            // the field top, 172-175 inside it, 20% toward the background, until the bubble leaves
            // the field). The tint is only on during `tintOverBubble`.
            for l in [glass, rim, veil, buttons.layer] { l.isHidden = nativeChrome }
            // The view itself too: a hidden layer's NSView still redraws at every size change.
            buttons.isHidden = nativeChrome
            if !nativeChrome { buttons.setNeedsDisplay(); renderGlass() }
        }
    }
    /// Field height changed in this transaction: (old, new, element, begin).
    var onFieldResize: ((CGFloat, CGFloat, SpringElement, CFTimeInterval) -> Void)?
    /// The field changed height at once (attachments): the native glass follows without animation.
    var onFieldJump: (() -> Void)?
    /// The attachments changed (the host's hover tracking follows them).
    var onAttachmentsChanged: (() -> Void)?
    /// The send's field opacity pulse (begin), for the live glass view.
    var onSendPulse: ((CFTimeInterval) -> Void)?

    static func height(lines: Int, chips: Bool) -> CGFloat { ComposeMetrics.height(lines: lines, chips: chips) }
    /// per view (several Home tabs), from this compose bar's width.
    var textWidth: CGFloat { ComposeView.fieldWidth(bounds.width) - 24 }
    static func fieldWidth(_ windowWidth: CGFloat) -> CGFloat { 526 + windowWidth - Fixture.windowWidth }
    static let font = Fixture.bodyFont
    static let maxLines = 8
    /// `writingTools`' raw value for reports: -1 on macOS 14 (no Writing Tools).
    static var writingToolsRaw: Int {
        if #available(macOS 15, *) { return writingTools.rawValue }
        return -1
    }
    @available(macOS 15, *)
    static let writingTools: NSWritingToolsBehavior = {
        let a = ProcessInfo.processInfo.arguments
        switch a.firstIndex(of: "--writing-tools").flatMap({ a.dropFirst($0 + 1).first }) /* no index math */ {
        case "none": return .none
        case "complete": return .complete
        case "default": return .default
        default: return .limited
        }
    }()
    /// per view (several Home tabs): this compose bar's width and its own memo.
    func lines(_ text: String) -> Int {
        // One-entry memo: every compose update asks again for the same draft (a send asks for "").
        let w = textWidth
        // The empty field (every send and every commit after it) has its own entry: the one-entry
        // memo held the last typed draft, so each send typeset " " again.
        if text.isEmpty, let e = emptyLinesMemo, e.0 == w { return e.1 }
        if let m = linesMemo, m.0 == text, m.1 == w { return m.2 }
        let n = min(ComposeView.maxLines, TextLayout.make(text.isEmpty ? " " : text, runs: [], maxWidth: w, font: ComposeView.font).lines.count)
        if text.isEmpty { emptyLinesMemo = (w, n) } else { linesMemo = (text, w, n) }
        return n
    }
    private var linesMemo: (String, CGFloat, Int)?
    private var emptyLinesMemo: (CGFloat, Int)?
    /// The placeholders, localized once (each `Strings` read is a bundle table lookup; every
    /// commit asked for one).
    private static let placeholders = (field: Strings.placeholder, reply: Strings.replyPlaceholder)
    private var dx: CGFloat { bounds.width - Fixture.windowWidth }
    private var dy: CGFloat { bounds.height - Fixture.windowSize.height }
    var anchorBase: CGFloat { ComposeMetrics.anchorBase + dy }
    var fieldBottom: CGFloat { ComposeMetrics.fieldBottom + dy }
    static let fieldX: CGFloat = 51
    static let firstBaseline: CGFloat = ComposeMetrics.firstBaseline

    static var typing: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = Fixture.lineHeight
        p.maximumLineHeight = Fixture.lineHeight
        return [.font: Fixture.bodyFont, .foregroundColor: Fixture.incomingText, .kern: Fixture.bodyKern, .paragraphStyle: p]
    }
    /// UITextView's text container inset above the first line (Catalyst value).
    static let textTopInset: CGFloat = ComposeView.firstBaseline - 13.26 - 0.25
    /// The space under the last line when the field scrolls (past `maxLines`), scrolled to the end:
    /// real Messages, 20 pasted lines (compose-e2e messages, 2026-10-09): the caret 2.1 pt above
    /// the glass's bottom, its line 4.35 pt (unscrolled, 8.2 pt: the field's own margin). Up to
    /// `maxLines` lines the document (top inset, lines, this) is shorter than the field, so nothing
    /// scrolls and the text sits where it sat.
    static let textBottomInset: CGFloat = 4.35
    /// The field's scroll bar (an overlay scroller while the field scrolls). Off: Messages shows none
    /// (not in a trackpad scroll over the field either, same take).
    static let showsScroller = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        let none: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
        for l in [glass, placeholderLayer, waveLayer, chipsLayer, caret, textSnapshot, overlay, veil, rim, tint, plusLayer] {
            l.actions = none; l.contentsScale = DisplayScale.current
        }
        buttons.isUserInteractionEnabled = false
        // weak capture, not unowned (crash program: no trap after the view is freed).
        buttons.drawer = { [weak self] ctx, _ in self?.drawButtons(ctx) }
        addSubview(buttons)
        glass.anchorPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(glass)
        layer.addSublayer(chipsLayer)
        overlay.name = ComposeView.overlayName
        veil.anchorPoint = CGPoint(x: 0.5, y: 1)
        veil.opacity = Animate.hiddenOpacity
        overlay.addSublayer(veil)
        tint.anchorPoint = CGPoint(x: 0.5, y: 1)
        tint.cornerRadius = 15
        tint.opacity = Animate.hiddenOpacity
        overlay.addSublayer(tint)
        rim.anchorPoint = CGPoint(x: 0.5, y: 1)
        overlay.addSublayer(rim)
        overlay.addSublayer(placeholderLayer)
        overlay.addSublayer(waveLayer)
        layer.addSublayer(textSnapshot)
        textSnapshot.isHidden = true
        textSnapshot.contentsGravity = .topLeft
        textSnapshot.masksToBounds = true

        let tv = textView.view
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.font = ComposeView.font
        tv.textColor = Fixture.incomingText
        tv.insertionPointColor = Fixture.caret
        tv.installCaret()
        tv.textContainer?.lineFragmentPadding = 0
        // AppKit puts `textContainerInset.height` above and below the text when it sizes the
        // document; the container origin puts the text at the top inset.
        tv.textTopInset = ComposeView.textTopInset
        tv.textContainerInset = NSSize(width: 0, height: (ComposeView.textTopInset + ComposeView.textBottomInset) / 2)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.typingAttributes = ComposeView.typing
        // The document of the field's scroll view (ComposeTextView): as tall as its text, at
        // least the field.
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: ComposeView.fieldWidth(Metrics.current.width) - 24, height: CGFloat.greatestFiniteMagnitude)
        tv.layerContentsPlacement = .topLeft
        tv.layer?.masksToBounds = true
        tv.layer?.contentsGravity = .topLeft
        tv.layer?.contentsScale = DisplayScale.current
        // Text services, decided explicitly (README: Text):
        // - continuous spell checking on (Messages underlines misspellings), run by
        //   DeferredSpellChecker off the keystroke frame (SpellCheck.swift);
        //   grammar checking off;
        // - automatic spelling correction, text replacement and quote/dash
        //   substitution follow the user's system settings (NSSpellChecker's
        //   global switches), as in every AppKit text view;
        // - Writing Tools `.limited` by default: the panel from the context
        //   and Edit menus, no inline rewrite of the field;
        //   `--writing-tools none|limited|complete|default`.
        tv.isContinuousSpellCheckingEnabled = DeferredSpellChecker.useAppKit
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = NSSpellChecker.isAutomaticSpellingCorrectionEnabled
        tv.isAutomaticTextReplacementEnabled = NSSpellChecker.isAutomaticTextReplacementEnabled
        tv.isAutomaticQuoteSubstitutionEnabled = NSSpellChecker.isAutomaticQuoteSubstitutionEnabled
        tv.isAutomaticDashSubstitutionEnabled = NSSpellChecker.isAutomaticDashSubstitutionEnabled
        if #available(macOS 15, *) { tv.writingToolsBehavior = ComposeView.writingTools }
        tv.setAccessibilityLabel(Strings.placeholder)

        caret.backgroundColor = Fixture.caret.cgColor
        caret.isHidden = true
        layer.addSublayer(caret)
        layer.addSublayer(plusLayer)
        layer.addSublayer(overlay)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var laidOut = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOut else { return }
        laidOut = bounds.size
        CATransaction.begin(); CATransaction.setDisableActions(true)
        overlay.frame = frame
        plusLayer.frame = plusRect
        CATransaction.commit()
        buttons.frame = CGRect(x: 0, y: 995 + dy, width: bounds.width, height: 40)
        // Hidden under AppKit's glass buttons in the live window: no redraw at every width.
        if !nativeChrome { buttons.setNeedsDisplay() }
        // The drawn glass is hidden under AppKit's glass in the live window (nativeChrome): it is
        // drawn when shown, not at every width of a live resize; the placeholder does not depend on
        // the width (both were about a tenth of each resize frame on main, dogfood 2026-10-08).
        if !nativeChrome { renderGlass() }
        if placeholderScale != DisplayScale.current { renderPlaceholder() }
        place(height: fieldHeight)
    }

    /// The display scale changed: draw every image again at the new scale.
    func rescale() {
        for l in [glass, placeholderLayer, waveLayer, chipsLayer, caret, textSnapshot, overlay, veil, rim] { l.contentsScale = DisplayScale.current }
        textView.view.applyScale()
        renderGlass()
        renderPlaceholder()
        renderChips()
        buttons.setNeedsDisplay()
    }

    /// The "+" button (opens the file picker).
    var plusRect: CGRect { CGRect(x: 10.5, y: 1000 + dy, width: 31, height: 30) }

    var fieldRect: CGRect { rect(height: fieldHeight) }
    func rect(height h: CGFloat) -> CGRect {
        CGRect(x: ComposeView.fieldX, y: fieldBottom - h - 0.25, width: ComposeView.fieldWidth(bounds.width), height: h)
    }

    /// Text view frame (window coordinates) for a field height.
    private func textFrame(height h: CGFloat) -> CGRect {
        let f = rect(height: h)
        let chipH: CGFloat = strip.height
        return CGRect(x: f.minX + 12, y: f.minY + chipH, width: f.width - 24 - (text.isEmpty ? 30 : 0), height: f.height - chipH)
    }

    /// What the last `place` laid out (field height, empty text, chip row height, size): a commit
    /// that changes none of them (a receive, a status, a keystroke on the same line) skips it.
    private var placed: (CGFloat, Bool, CGFloat, CGSize)?
    private func place(height h: CGFloat) {
        placed = (h, text.isEmpty, strip.height, bounds.size)
        let f = rect(height: h)
        let chipH: CGFloat = strip.height
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glass.bounds = CGRect(x: 0, y: 0, width: f.width, height: f.height)
        glass.position = CGPoint(x: f.midX, y: f.maxY)
        for l in [veil, rim, tint] { l.bounds = glass.bounds; l.position = glass.position }
        tint.backgroundColor = Fixture.background.withAlphaComponent(0.2).cgColor
        placeholderLayer.frame = CGRect(x: f.minX, y: f.minY + chipH, width: 300, height: 30)
        waveLayer.frame = CGRect(x: f.maxX - 30, y: f.maxY - 30, width: 24, height: 30)
        chipsLayer.frame = CGRect(x: f.minX, y: f.minY, width: f.width, height: max(1, strip.height))
        strip.update(chips, width: f.width, scale: DisplayScale.current)
        textSnapshot.frame = textFrame(height: h)
        CATransaction.commit()
        textView.place(textFrame(height: h))
    }

    /// Glass field image: top and bottom rims are fixed, the middle stretches.
    private func renderGlass() {
        let w = ComposeView.fieldWidth(bounds.width)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.opaque = false
        let h: CGFloat = 31
        glass.contents = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { _ in
            NSColor(white: 49 / 255, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: 15).fill()
        }.cgImage
        rim.contents = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { ctx in
            Glass.drawRim(ctx.cgContext, rect: CGRect(x: 0, y: 0, width: w, height: h), radius: 15, rim: .field)
        }.cgImage
        for l in [glass, rim] {
            l.contentsCenter = CGRect(x: 0, y: 15 / h, width: 1, height: 1 / h)
            l.contentsScale = fmt.scale
        }
        renderVeil(width: w)
    }

    /// The glass over a bubble inside the field (catalyst's measured profile).
    private func renderVeil(width w: CGFloat) {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.opaque = false
        let cap: CGFloat = 20, h = 2 * cap + 1
        let top: [(CGFloat, CGFloat)] = [(0, 0.26), (6, 0.25), (9, 0.2), (13, 0.14), (16, 0.08), (18, 0.06), (20, 0)]
        let bottom: [(CGFloat, CGFloat)] = [(0, 0.35), (2, 0.34), (6, 0.29), (10, 0.2), (13, 0.14), (17, 0.08), (20, 0)]
        veil.contents = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { ctx in
            let c = ctx.cgContext
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            c.saveGState()
            UIBezierPath(roundedRect: rect, cornerRadius: 15).addClip()
            let grey = NSColor(white: 55 / 255, alpha: 1)
            let space = CGColorSpace(name: CGColorSpace.sRGB)
            for (stops, fromTop) in [(top, true), (bottom, false)] {
                // an optional gradient draws nothing when it fails (CrashSafeGraphics).
                let g = CGGradient(colorsSpace: space, colors: stops.map { grey.withAlphaComponent($0.1).cgColor } as CFArray,
                                   locations: stops.map { $0.0 / cap })
                c.drawLinearGradient(g, start: CGPoint(x: 0, y: fromTop ? 0 : h), end: CGPoint(x: 0, y: fromTop ? cap : h - cap), options: [])
            }
            c.restoreGState()
        }.cgImage
        veil.contentsCenter = CGRect(x: 0, y: cap / h, width: 1, height: 1 / h)
        veil.contentsScale = fmt.scale
    }

    /// The scale the placeholder and the waveform were drawn at (nil: not drawn).
    private var placeholderScale: CGFloat?
    private func renderPlaceholder() {
        placeholderScale = DisplayScale.current
        let fmt = UIGraphicsImageRendererFormat()
        fmt.opaque = false
        let ph = placeholder
        placeholderLayer.contents = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 30), format: fmt).image { ctx in
            TextDraw.line(ph, font: ComposeView.font, color: Fixture.placeholder, x: 12, baseline: ComposeView.firstBaseline, in: ctx.cgContext)
        }.cgImage
        placeholderLayer.contentsScale = fmt.scale
        waveLayer.contents = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 30), format: fmt).image { _ in
            Fixture.waveform.setFill()  // cmux: themed (with the placeholder above)
            // Messages' glyph is ChatKit's AudioMessageEntryViewButton waveform at 20 pt
            // (fitted to the lossless stills): 5 capsules 1.818 pt wide, 3.636 pt apart,
            // 3.613 / 7.25 / 14.522 pt tall; centre 557.5 pt from the left of a 628 pt window.
            let c = CGPoint(x: 10.5, y: 14.5)
            for (i, hh) in ([3.613, 7.25, 14.522, 7.25, 3.613] as [CGFloat]).enumerated() {
                let x = c.x + CGFloat(i - 2) * 3.636
                UIBezierPath(roundedRect: CGRect(x: x - 0.909, y: c.y - hh / 2, width: 1.818, height: hh), cornerRadius: 0.909).fill()
            }
        }.cgImage
        waveLayer.contentsScale = fmt.scale
    }

    private func renderChips() {
        strip.update(chips, width: ComposeView.fieldWidth(bounds.width), scale: DisplayScale.current)
    }

    /// The attachment whose remove control is at p (window coordinates).
    func chip(at p: CGPoint) -> ID? {
        let f = fieldRect
        return strip.removeHit(CGPoint(x: p.x - f.minX, y: p.y - f.minY))
    }

    /// The field's glass is animating its height (tests).
    var glassAnimating: Bool { (glass.animationKeys() ?? []).contains { $0.contains("bounds") } }
    var glassKeys: [String] { glass.animationKeys() ?? [] }

    /// Hover over the attachments (window coordinates; nil: outside): an image
    /// shows its remove button.
    func hoverAttachments(_ p: CGPoint?) {
        let f = fieldRect
        strip.hover(p.map { CGPoint(x: $0.x - f.minX, y: $0.y - f.minY) })
    }

    /// Mirror the draft and animate the field to its new height in this
    /// transaction (catalyst's `ComposeView.update`).
    func update(state: AppState, send: Bool, begin: CFTimeInterval) {
        let d = state.ui.draft
        let tv = textView.view
        if tv.string != d.text {
            // Never replace text that holds marked (IME) text: the input
            // method owns it until it commits.
            if !tv.hasMarkedText() {
                tv.textStorage?.setAttributedString(NSAttributedString(string: d.text, attributes: ComposeView.typing))
                tv.typingAttributes = ComposeView.typing
                if !DeferredSpellChecker.useAppKit { tv.spell.textDidChange() }
            }
        }
        let newPlaceholder = state.ui.openThread != nil ? ComposeView.placeholders.reply : ComposeView.placeholders.field
        if newPlaceholder != placeholder { placeholder = newPlaceholder; renderPlaceholder(); tv.setAccessibilityLabel(placeholder) }
        // Messages grows the field for an attachment at once (no in-between frame at
        // 120 Hz, compose-attach-image paste take); typing still uses the growth spring.
        let attachmentsChanged = d.attachments != chips
        if attachmentsChanged { chips = d.attachments; renderChips(); onAttachmentsChanged?() }
        text = d.text
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // With an attachment Messages shows neither the placeholder nor the audio glyph
        // (compose-attach-image stills).
        placeholderLayer.opacity = text.isEmpty && chips.isEmpty ? 1 : 0
        waveLayer.opacity = text.isEmpty && chips.isEmpty ? 1 : 0
        CATransaction.commit()
        let h = ComposeView.height(lines: lines(d.text), chips: false) + strip.height  // per view
        let old = fieldHeight
        fieldHeight = h
        if attachmentsChanged || placed.map({ $0.0 != h || $0.1 != text.isEmpty || $0.2 != strip.height || $0.3 != bounds.size }) ?? true {
            place(height: h)
        }
        if h != old && attachmentsChanged && !send {
            onFieldJump?()
        } else if h != old {
            let e = send ? Springs.fieldTop : Springs.fieldGrow
            onFieldResize?(old, h, e, begin)
            Animate.scalar(glass, "bounds.size.height", from: Double(old), to: Double(h), e, begin: begin)
            for l in [veil, rim, tint] { Animate.scalar(l, "bounds.size.height", from: Double(old), to: Double(h), e, begin: begin) }
            let dTop = Double(h - old)
            for l in [placeholderLayer, chipsLayer] {
                Animate.scalar(l, "position.y", from: Double(l.position.y) + dTop, to: Double(l.position.y), e, begin: begin)
            }
            // The text view's top stays on the field top: Catalyst animates
            // the center by half the growth and the height by the growth
            // (anchor 0.5). The field's clip layer (ComposeTextView.clip, around
            // the text view) is anchored at its top-left, so its top moves by the
            // growth: the same frames.
            for l in [textView.layer, textSnapshot] {
                let top = l.anchorPoint.y == 0 ? dTop : dTop / 2
                Animate.scalar(l, "position.y", from: Double(l.position.y) + top, to: Double(l.position.y), e, begin: begin)
                Animate.scalar(l, "bounds.size.height", from: Double(l.bounds.height) - dTop, to: Double(l.bounds.height), e, begin: begin)
            }
        }
        if send {
            Animate.sampledPulse(glass, "opacity", Springs.fieldOpacity, base: 1, begin: begin)
            Animate.sampledPulse(rim, "opacity", Springs.fieldOpacity, base: 1, depth: ComposeView.rimFadeDepth, begin: begin)
            Animate.sampledUntilMinimum(veil, "opacity", Springs.fieldOpacity, base: 1, begin: begin)
            onSendPulse?(begin)
        }
    }

    /// The glass over a bubble still inside the field after the fill has
    /// faded (catalyst's `tintOverBubble`).
    func tintOverBubble(begin: CFTimeInterval, exit: CFTimeInterval) {
        let e = Springs.fieldOpacity
        let n = max(2, CrashGuard.int((exit - begin) * 240, in: 0...14_400) + 1) // at most 60 s, no trap on NaN
        let samples: [Double] = (0...n).map { min(1, max(0, e.value(Double($0) / 240, from: 1, to: 1))) }
        // no index math.
        let low = samples.enumerated().min { $0.element < $1.element }?.offset ?? n
        let values = samples.enumerated().map { $0.offset < low || $0.offset == n ? 0 : 1 - $0.element }
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = values.map { NSNumber(value: $0) }
        a.keyTimes = (0...n).map { NSNumber(value: Double($0) / Double(n)) }
        a.duration = Double(n) / 240
        a.beginTime = begin
        a.calculationMode = .linear
        a.fillMode = .backwards
        a.isRemovedOnCompletion = true
        tint.add(a, forKey: "tintOverBubble")
    }

    /// Capture mode: draw the text view into `textSnapshot` (the NSTextView
    /// draws itself; this only copies its pixels into the captured tree).
    func refreshTextSnapshot() {
        guard captureMode else { return }
        let tv = textView.view
        tv.layoutSubtreeIfNeeded()
        // The part of the document in the field (all of it up to `maxLines` lines).
        let shown = tv.visibleRect.isEmpty ? tv.bounds : tv.visibleRect
        let size = shown.size
        guard size.width > 0, size.height > 0, var rep = tv.bitmapImageRepForCachingDisplay(in: shown) else { return }
        // AppKit sizes the cache for the main screen when the view has no window (1x on a Mac
        // whose main display is 1x); the snapshot is drawn at the scale of the tree it goes into.
        let scale = tv.window?.backingScaleFactor ?? DisplayScale.current
        // no trap on a NaN or huge size (crash ratchet)
        let wide = CrashGuard.int((size.width * scale).rounded(.up), in: 0...1 << 16), high = CrashGuard.int((size.height * scale).rounded(.up), in: 0...1 << 16)
        if rep.pixelsWide != wide || rep.pixelsHigh != high,
           let scaled = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high,
                                         bitsPerSample: rep.bitsPerSample, samplesPerPixel: rep.samplesPerPixel,
                                         hasAlpha: rep.hasAlpha, isPlanar: rep.isPlanar, colorSpaceName: rep.colorSpaceName,
                                         bitmapFormat: rep.bitmapFormat, bytesPerRow: 0, bitsPerPixel: rep.bitsPerPixel)?
            .retagging(with: rep.colorSpace) {
            scaled.size = size
            rep = scaled
        }
        tv.cacheDisplay(in: shown, to: rep)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        textSnapshot.contents = rep.cgImage
        textSnapshot.contentsScale = CGFloat(rep.pixelsWide) / max(1, size.width)
        CATransaction.commit()
    }

    /// Capture-mode caret (catalyst's `applyCaret`).
    func applyCaret(sinceEdit tau: Double, sinceSend: Double?) {
        guard captureMode else { return }
        refreshTextSnapshot()
        var alpha = 1.0, gray = false
        if let s = sinceSend, s >= 0, s < 0.65 { alpha = s < 0.02 ? 0 : 1; gray = true }
        else if tau >= 0.99 {
            let p = (tau - 0.99).truncatingRemainder(dividingBy: 1.0)
            alpha = p < 0.6 ? 1 : p < 0.65 ? 1 - (p - 0.6) / 0.05 : p < 0.95 ? 0 : (p - 0.95) / 0.05
        }
        let f = fieldRect
        let tl = TextLayout.make(text.isEmpty ? " " : text, runs: [], maxWidth: textWidth, font: ComposeView.font)
        let row = CGFloat(max(0, tl.lines.count - 1))
        let last = text.isEmpty ? "" : (text.components(separatedBy: "\n").last ?? "")
        let cx = f.minX + 12 + TextDraw.width(last, font: ComposeView.font, kern: Fixture.bodyKern)
        let base = f.minY + (strip.height) + ComposeView.firstBaseline
        CATransaction.begin(); CATransaction.setDisableActions(true)
        caret.frame = CGRect(x: cx.px, y: base - 12.5 + row * 16, width: 1, height: 16.5)
        caret.backgroundColor = (gray ? NSColor(white: 0.5, alpha: 1) : Fixture.caret).cgColor
        caret.opacity = Float(alpha)
        CATransaction.commit()
    }

    private func drawButtons(_ ctx: CGContext) {
        ctx.translateBy(x: 0, y: -(995 + dy))
        Glass.draw(ctx, rect: CGRect(x: 10.5, y: 1000 + dy, width: 31, height: 30), radius: 15, fill: 49, rim: .button)
        Glass.draw(ctx, rect: CGRect(x: 586.5 + dx, y: 1000 + dy, width: 31, height: 30), radius: 15, fill: 49, rim: .button)
        // Fitted to the lossless stills: plus 15.5 pt medium, emoji.face.grinning 15.5 pt medium.
        let cfg = UIImage.SymbolConfiguration(pointSize: 15.5, weight: .medium)
        if let img = UIImage(systemName: "plus", withConfiguration: cfg)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
            let s = img.size, c = CGPoint(x: 26, y: 1015.25 + dy)
            img.draw(in: CGRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height))
        }
        if let img = FieldChrome.emojiGlyph() {
            let s = img.size, c = CGPoint(x: 601.875 + dx, y: 1014.875 + dy)
            img.draw(in: CGRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height))
        }
    }
}
