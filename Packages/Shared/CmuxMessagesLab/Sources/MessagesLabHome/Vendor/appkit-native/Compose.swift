import AppKit

/// The compose field's NSTextView: Return sends, Option/Shift+Return adds a
/// newline, Esc cancels, and pasted images become attachments (Catalyst's
/// `ComposeTextView` key commands). IME marked text, the caret and selection
/// are AppKit's own.
final class FieldTextView: NSTextView {
    var onSend: () -> Void = {}
    var onEscape: () -> Void = {}
    /// cmux: optional; nil (Home: the host's intake takes pictures) skips the picture decode
    /// a declined paste made only to throw the image away.
    var onPasteImage: ((NSImage) -> Void)?
    /// cmux: the host's attachment intake reads the pasteboard first
    /// (files and pictures, Home's type rule); true when it took the paste.
    var onPastePasteboard: (NSPasteboard) -> Bool = { _ in false }
    /// cmux: whether the host's intake would take the pasteboard (types only).
    /// A plain-text NSTextView enables Paste only for text types, so a
    /// picture alone (a copied screenshot) left Cmd+V disabled.
    var acceptsPastePasteboard: (NSPasteboard) -> Bool = { _ in false }
    /// cmux: a drop on the field that the host's intake takes (the paste's
    /// type rule). A plain-text NSTextView would type a dropped file's path.
    var onDropPasteboard: (NSPasteboard) -> Bool = { _ in false }
    /// cmux: whether the host's intake would take a drag's pasteboard (a drag also counts
    /// file promises, which a paste cannot receive); nil uses `acceptsPastePasteboard`.
    var acceptsDropPasteboard: ((NSPasteboard) -> Bool)?
    /// cmux: the words a paste the host's intake took carries beside its attachments (a note's
    /// text around its pictures); the field inserts them at the caret. Nil: none.
    var pasteTextBesideAttachments: (NSPasteboard) -> String? = { _ in nil }
    /// cmux: a draft attachment's file, named like it: Copy of a selection holding attachments
    /// writes the files (ComposeSelectionCopy.swift). Nil: none here.
    var draftAttachmentFile: (ID) -> URL? = { _ in nil }
    /// cmux: the field became (true) or stopped being (false) the target of a drag the host's
    /// intake takes: the pane's drop highlight follows it.
    var onDropTargetChange: (Bool) -> Void = { _ in }
    /// Marked (IME) text changed. UITextView reports marked text through
    /// `textViewDidChange`, so the draft (and the field height) follows the
    /// composition; NSTextView does not post a text change for it.
    var onMarkedTextChange: () -> Void = {}
    /// A press in the field (before the text view tracks it): the field glass's press light.
    var onPress: (NSEvent) -> Void = { _ in }
    /// The release of that press (the mouse-up that ended the text view's tracking).
    var onRelease: (NSEvent) -> Void = { _ in }
    override func mouseDown(with event: NSEvent) {
        pickerAnchor = nil  // cmux
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
        // cmux: in a zoomed Chief chat (MessagesLabHomeView.zoom) the text draws at the window's scale times the zoom,
        // so the magnified field text stays sharp.
        let s = window.map { $0.backingScaleFactor * enclosingContentZoom } ?? DisplayScale.current
        if let l = layer, l.contentsScale != s { l.contentsScale = s }
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); applyScale() }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        pickerAnchor = nil  // cmux: an input method's window goes at the caret
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedTextChange()
    }

    override func keyDown(with event: NSEvent) {
        if Self.caretLog { Self.log("key down \(event.keyCode)"); Self.logRunLoop() }
        pickerAnchor = nil  // cmux
        defer { if Self.caretLog { Self.log("key done") } }
        // Marked text (IME composition) owns Return and Esc.
        if hasMarkedText() { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 || event.keyCode == 76 {
            if flags.contains(.option) || flags.contains(.shift) { insertText("\n", replacementRange: selectedRange()); return }
            onSend(); return
        }
        // cmux: Ctrl+J (keyCode 38) is a newline, as in a terminal.
        if event.keyCode == 38, flags == .control { insertText("\n", replacementRange: selectedRange()); return }
        if event.keyCode == 53 { onEscape(); return }
        super.keyDown(with: event)
    }

    // MARK: Caret (UIKit's, as Messages draws it)

    /// Messages' caret is UIKit's, not AppKit's insertion indicator (lossless references,
    /// macOS 27): it shows at once when the field takes focus or the caret moves (AppKit's
    /// fades in over 0.15 s), stays solid 0.56 s, then blinks with a 1.0 s period in four
    /// steps of 25 % about 35 ms apart (out at +0.56, in at +0.90); it is 2 x 17 pt with round ends, its
    /// left edge 0.5 pt left of and 1.25 pt below AppKit's 1 x 16 pt one. AppKit's blink has the same period,
    /// so only the reset, the fade-in and the geometry differ; this layer replaces it.
    private let caretView = CaretView()
    /// A plain sublayer of the caret view's layer (AppKit manages the view's own layer).
    let caretLayer = CALayer()
    /// Off: AppKit's own indicator (`--appkit-caret`, and capture mode, which draws its own).
    static let ownCaret = !ProcessInfo.processInfo.arguments.contains("--appkit-caret")
    /// `--caret-log`: caret placements and blink restarts to /tmp/caret.log (diagnostics).
    static let caretLog = ProcessInfo.processInfo.arguments.contains("--caret-log")
    static func log(_ s: String) {
        // Host time first (CACurrentMediaTime: the clock of the recorder's frame times).
        let line = String(format: "%.6f ", CACurrentMediaTime()) + s + "\n"
        let url = URL(fileURLWithPath: "/tmp/caret.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }
    /// `--caret-log`: the main run loop's waits, to place each key's work between Core Animation's
    /// commits (the implicit transaction commits before the run loop waits).
    private static var runLoopLog: CFRunLoopObserver?
    static func logRunLoop() {
        guard caretLog, runLoopLog == nil else { return }
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue, true, Int.max) { _, act in
            log(act == .beforeWaiting ? "runloop wait" : "runloop wake")
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        runLoopLog = o
    }
    var caretSuspended = false { didSet { updateCaret(reset: false) } }

    /// cmux: the caret's colour after a palette change (it was set once, when the field was made).
    func recolorCaret() {
        caretLayer.backgroundColor = Fixture.caret.cgColor
        if !Self.ownCaret, insertionPointColor != .clear { insertionPointColor = Fixture.caret }
    }

    func installCaret() {
        guard Self.ownCaret else { return }
        insertionPointColor = .clear
        caretView.wantsLayer = true
        caretView.layer?.addSublayer(caretLayer)
        caretLayer.frame = CGRect(x: 0, y: 0, width: Self.caretWidth, height: 17)
        // UIKit's caret ends are round (lossless references: the first and last two device rows of the
        // 2 pt column are 42 % and 77 % covered at each side).
        caretLayer.cornerRadius = Self.caretWidth / 2
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
        if Self.caretLog { Self.log("caret update reset \(reset)") }
        if show {
            // The caret's place in the text view (TextKit 2's caret segment, the text laid out), then in
            // the host: right also before the field's first layout. AppKit's `firstRect` is in screen
            // coordinates and gave a zero rect while the field was outside the window (focus before the
            // window's first layout: --caret-log line (-1675, -57, 0, 0), the caret hidden; the layout
            // that brought the field in moved no view of the field, so the caret stayed hidden).
            let local: CGRect
            if let r = caretRect(at: sel.location, upstream: textLayoutManager?.textSelections.first?.affinity == .upstream) {
                local = CGRect(x: r.minX + Self.caretDX, y: r.minY, width: Self.caretWidth, height: 17)
            } else {
                // cmux: AppKit's own rect, never the emoji picker's anchor (`pickerAnchor`).
                let screen = super.firstRect(forCharacterRange: NSRange(location: sel.location, length: 0), actualRange: nil)
                let r = convert(window.convertFromScreen(screen), from: nil)
                local = CGRect(x: r.minX + Self.caretDX, y: r.midY + Self.caretDY, width: Self.caretWidth, height: 17)
            }
            caretFrame = convert(local, to: host)
            // A caret line scrolled out of the field (past `ComposeView.maxHeight`) hides the caret,
            // as UIKit's in Messages' field.
            if let clip = fieldClip {
                let v = clip.convert(clip.bounds, to: host)
                show = caretFrame.midY >= v.minY && caretFrame.midY <= v.maxY
            }
            if Self.caretLog { Self.log("line \(local) caret \(caretFrame) shown \(show) reset \(reset)") }
        }
        guard show else { caretView.isHidden = true; caretLayer.removeAllAnimations(); return }
        caretView.frame = caretFrame
        let wasHidden = caretView.isHidden
        caretView.isHidden = false
        if reset || wasHidden || caretLayer.animation(forKey: "blink") == nil { startBlink() }
    }

    /// The caret as drawn (self-test): shown, its frame in the field's host, its blink running.
    var caretState: (shown: Bool, frame: CGRect, blinks: Bool) {
        (!caretView.isHidden && caretView.superview != nil, caretView.frame, caretLayer.animation(forKey: "blink") != nil)
    }

    /// Caret geometry against the line rect AppKit reports: Messages' caret is 62.5-64.5 x
    /// 1006-1023 pt in the 31 pt one-line field (field-focus-type, deactivate-activate, every
    /// send take while typing), 7 pt under the field top; 1007-1024 in the 30 pt field after a send
    /// (the first fit, 1007-1024, was of that field: ours sat 1 pt low while typing).
    static let caretDX: CGFloat = -0.5, caretDY: CGFloat = -8.5 + 0.75
    /// Messages' caret is 2 pt wide (62.5-64.5 pt, device columns 125-128 at 2x, in every lossless
    /// reference with the empty field: deactivate-activate, send-typed, receive-media, swipe-full; the
    /// placeholder's "i" stem shares columns 127-128, which read as a 1 pt caret before), with round ends.
    static let caretWidth: CGFloat = 2

    /// Solid time after a reset (references: 0.55 s in reply-menu-send, 0.58 s in field-focus-type).
    static let caretSolid: CFTimeInterval = 0.56

    /// `--still-grab` (still scenes, test only): the caret stays solid, its state in the grab does
    /// not depend on the blink's phase at the grab (Messages' still references show it solid).
    static let solidCaret = ProcessInfo.processInfo.arguments.contains("--still-grab")

    // cmux: not private, so a Reduce Motion change restarts or stills the blink (cx-sya4n).
    func startBlink() {
        if Self.caretLog { Self.log("blink restart \(CACurrentMediaTime())") }
        caretLayer.removeAnimation(forKey: "blink")
        caretLayer.opacity = 1
        // cmux: under Reduce Motion the caret holds solid (cx-sya4n: nothing loops).
        if Self.solidCaret || MessagesLabHomeView.reducesMotion { return }
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

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let ok = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if ok { editing = true }
        return ok
    }
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        pickerAnchor = nil  // cmux
        caretByEdit = editing
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // A caret move (an arrow key) shows the caret by this rule whatever AppKit scrolls; an
        // edit's caret is shown after the edit's layout (`scrollRangeToVisible`, `setFrameSize`).
        if !editing, !stillSelecting, frame.height > (enclosingScrollView?.contentSize.height ?? .infinity) + 0.5 { scrollCaretIntoField() }
        updateCaret()
        if !stillSelecting, !DeferredSpellChecker.useAppKit { spell.selectionDidChange() }
    }
    override func didChangeText() {
        editing = false
        caretByEdit = true
        super.didChangeText()
        updateCaret()
        if !DeferredSpellChecker.useAppKit { spell.textDidChange() }
    }

    /// Spell checking while typing, off the keystroke frame (SpellCheck.swift); the Edit
    /// menu's "Check Spelling While Typing" switches it.
    lazy var spell = DeferredSpellChecker(view: self)
    /// Enables the host's opt-in composer spell checking without changing the system-wide setting.
    func setSpellCheckingEnabled(_ enabled: Bool) {
        if DeferredSpellChecker.useAppKit {
            isContinuousSpellCheckingEnabled = enabled
        } else {
            spell.enabled = enabled
        }
    }
    override func toggleContinuousSpellChecking(_ sender: Any?) {
        if DeferredSpellChecker.useAppKit { super.toggleContinuousSpellChecking(sender) } else { spell.enabled.toggle() }
    }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), acceptsPastePasteboard(pasteboard) { return true }  // cmux
        // cmux: Paste and Match Style reads the field's own pasteboard: text only.
        if item.action == #selector(pasteAsPlainText(_:)) { return isEditable && plainText(pasteboard) != nil }
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
        pickerAnchor = nil  // cmux
        let ok = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.updateCaret(reset: false) }
        return ok
    }
    // Block observers on queue: .main (inline for AppKit's post on main), not selectors: a selector
    // into this main-actor view traps on a post off main (cmux-next's objc_observer rule).
    private var keyObservers: [NSObjectProtocol] = []
    deinit {
        keyObservers.forEach { NotificationCenter.default.removeObserver($0) }
        storageObserver.map(NotificationCenter.default.removeObserver)
    }
    /// The text storage's edits (its `didProcessEditing` posts), the container's width and the layout
    /// objects when `caretRect` last laid out the whole text.
    private struct LayoutState: Equatable { var edits: Int; var width: CGFloat; var manager: ObjectIdentifier; var container: ObjectIdentifier? }
    private var laidOut: LayoutState?
    /// The layout inputs that are not in the text storage, so no `didProcessEditing` reports a change
    /// of them (hq-6d): the text view's font, typing attributes, default paragraph style and container
    /// inset (counted in `inputChanges` by their setters), and the container's and layout manager's
    /// settings. A change lays out the whole text again, from scratch. (On macOS 27 TextKit 2 already
    /// invalidated the caret's line for each input the self-test changes, so the line check alone was
    /// right there: self-test "caret: a layout input changed ...", 2026-10-12; this key does not depend
    /// on that undocumented behaviour, on any OS.)
    /// (`textContainerOrigin` and `textTopInset` are read at each call, not laid out.)
    private struct LayoutInputs: Equatable {
        var changes: Int
        var padding: CGFloat
        var maxLines: Int
        var lineBreak: NSLineBreakMode
        var exclusions: [NSBezierPath]
        var orientation: NSLayoutManager.TextLayoutOrientation
        var fontLeading: Bool
        var hyphenation: Bool
    }
    private var laidOutInputs: LayoutInputs?
    private var inputChanges = 0
    override var font: NSFont? { didSet { inputChanges &+= 1 } }
    override var defaultParagraphStyle: NSParagraphStyle? { didSet { inputChanges &+= 1 } }
    override var textContainerInset: NSSize { didSet { if textContainerInset != oldValue { inputChanges &+= 1 } } }
    // AppKit sets the typing attributes again at caret moves: only a different value counts.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        didSet { if !NSDictionary(dictionary: typingAttributes).isEqual(to: oldValue) { inputChanges &+= 1 } }
    }
    private var storageEdits = 0
    private var storageObserver: NSObjectProtocol?
    private var observedStorage: ObjectIdentifier?
    /// cmux: the field's typing undo is on the window's undo stack, which does not retain its
    /// targets; NSTextView registers it with the text storage as the target, not itself. A field
    /// leaving its window (Cmd+1…9, a rebuilt conversation or dock view) takes its entries off that
    /// stack; a freed field's left behind crashed the next Edit > Undo (`_undoRedoTextOperation:`
    /// to freed text, nightly 3934935376001).
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window, newWindow !== window, let stack = undoManager ?? window.undoManager {
            stack.removeAllActions(withTarget: self)
            if let storage = textStorage { stack.removeAllActions(withTarget: storage) }
        }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyScale()
        let nc = NotificationCenter.default
        keyObservers.forEach { nc.removeObserver($0) }
        keyObservers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
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
        // The field's width that waited for the end of the resize (ComposeTextView.place) first.
        onEndLiveResize()
        keepCaretInView()
    }
    /// The end of a live window resize (ComposeTextView: the deferred width).
    var onEndLiveResize: () -> Void = {}
    /// Scrolls the caret's line into the field (the clip of `ComposeTextView`), when the field scrolls.
    func keepCaretInView() {
        guard let sv = enclosingScrollView, frame.height > sv.contentSize.height + 0.5 else { return }
        scrollRangeToVisible(selectedRange())
    }

    // MARK: Caret scrolling (UITextView's, as Messages' field scrolls)

    /// An edit is between `shouldChangeText` and `didChangeText` (its selection change is the edit's).
    private var editing = false
    /// The caret was last placed by an edit (typing, paste, delete), not by a caret move.
    private var caretByEdit = false

    /// Messages' field (compose-e2e messages, 2026-10-10): a caret move (arrow keys) or a rewrap
    /// scrolls the field by the least that shows the caret, the caret flush with the field's top
    /// or bottom edge (AppKit's own scroll left the line 6 to 30 pt inside); an edit at the end of
    /// the text scrolls to the end, `ComposeView.textBottomInset` under the last line. A
    /// selection (not a caret) and a field without a window scroll as AppKit does.
    /// The caret's rect at INDEX in the document (as `updateCaret` places it): from TextKit 2's
    /// caret segment, after the field's whole text is laid out (TextKit 2 lays out only lines near
    /// the viewport, and a line outside it has an estimated place: lab e2e 2026-10-10, Up to line 1
    /// left the field at its end).
    /// UPSTREAM: the caret at a soft wrap is at the end of the line above (the selection's affinity).
    private func caretRect(at index: Int, upstream: Bool = false) -> CGRect? {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let loc = tcm.location(tcm.documentRange.location, offsetBy: index) else { return nil }
        // The whole text is laid out again only when an edit or a new container width can have
        // changed a line since the last time (or the caret's own line is not laid out): over a laid-out
        // text, `ensureLayout` still walks every line (caret bench, 20,000 characters: 0.15 ms per
        // call, 2 to 3 calls per key; arrow keys edit nothing).
        let storage = textStorage.map(ObjectIdentifier.init)
        if observedStorage != storage {
            storageObserver.map(NotificationCenter.default.removeObserver)
            storageObserver = textStorage.map {
                NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: $0, queue: .main) { [weak self] _ in
                    self?.storageEdits += 1
                }
            }
            observedStorage = storage
            laidOut = nil
        }
        let inputs = LayoutInputs(changes: inputChanges, padding: textContainer?.lineFragmentPadding ?? -1,
                                  maxLines: textContainer?.maximumNumberOfLines ?? -1, lineBreak: textContainer?.lineBreakMode ?? .byWordWrapping,
                                  exclusions: textContainer?.exclusionPaths ?? [], orientation: textContainer?.layoutOrientation ?? .horizontal,
                                  fontLeading: tlm.usesFontLeading, hyphenation: tlm.usesHyphenation)
        if inputs != laidOutInputs {
            // Kept first: a caret update inside the invalidation sees these inputs as laid out.
            let had = laidOutInputs != nil
            laidOutInputs = inputs
            laidOut = nil
            if had { tlm.invalidateLayout(for: tlm.documentRange) }
        }
        let state = LayoutState(edits: storageEdits, width: textContainer?.size.width ?? -1,
                                manager: ObjectIdentifier(tlm), container: textContainer.map(ObjectIdentifier.init))
        // The caret at the end of the text is in the last line's fragment (no fragment begins there).
        let end = index > 0 && loc.compare(tcm.documentRange.endLocation) == .orderedSame
        let probe = end ? tcm.location(loc, offsetBy: -1) ?? loc : loc
        if laidOut != state || tlm.textLayoutFragment(for: probe)?.state != .layoutAvailable {
            tlm.ensureLayout(for: tlm.documentRange)
            laidOut = state
        }
        func segment(upstream: Bool) -> CGRect? {
            var line: CGRect?
            tlm.enumerateTextSegments(in: NSTextRange(location: loc), type: .standard,
                                      options: upstream ? [.rangeNotRequired, .upstreamAffinity] : [.rangeNotRequired]) { _, r, _, _ in
                line = r; return false
            }
            return line
        }
        let o = textContainerOrigin
        // cmux: a picture takes its whole line, as in Messages (ComposeInlineAttachment).
        let storageText = textStorage
        func picture(_ i: Int) -> Bool {
            guard let s = storageText, i >= 0, i < s.length else { return false }
            return s.attribute(.attachment, at: i, effectiveRange: nil) is ComposeInlineAttachment
        }
        let length = storageText?.length ?? 0
        let next: unichar? = index < length ? (storageText?.string as NSString?)?.character(at: index) : nil
        let previous: unichar? = index > 0 && index <= length ? (storageText?.string as NSString?)?.character(at: index - 1) : nil
        // Right after a picture, where nothing follows on its line (the end, a line break or another
        // picture), the caret starts the line under it: the next character goes there.
        if picture(index - 1), next == nil || next == 0x0A || picture(index), let above = segment(upstream: true) {
            return CGRect(x: o.x, y: above.maxY + Fixture.lineHeight / 2 + o.y + Self.caretDY, width: Self.caretWidth, height: 17)
        }
        // Just before a picture that follows text, the caret ends the text's line above it.
        let beforePicture = picture(index) && previous != nil && previous != 0x0A && !picture(index - 1)
        guard let l = segment(upstream: upstream || beforePicture) else { return nil }
        // cmux: on a line an inline picture makes taller the text sits at the bottom, so the caret
        // is on the line's last text line, not its middle (Draft+InlineMarks.swift).
        let y = l.height > Fixture.lineHeight + 0.5 ? l.maxY - Fixture.lineHeight / 2 : l.midY
        return CGRect(x: l.minX + o.x, y: y + o.y + Self.caretDY, width: Self.caretWidth, height: 17)
    }
    /// Self-test: the caret's rects at INDICES from the layout as `caretRect` keeps it, then after the
    /// whole text is laid out again from scratch (equal when no layout input went stale).
    func caretRects(at indices: [Int]) -> (kept: [CGRect?], fresh: [CGRect?]) {
        let kept = indices.map { caretRect(at: $0) }
        if let tlm = textLayoutManager { tlm.invalidateLayout(for: tlm.documentRange) }
        laidOut = nil
        return (kept, indices.map { caretRect(at: $0) })
    }
    @discardableResult
    private func scrollCaretIntoField(_ range: NSRange? = nil) -> Bool {
        let sel = range ?? selectedRange()
        guard let sv = enclosingScrollView, window != nil, sel.length == 0, var target = caretRect(at: sel.location) else { return false }
        let clip = sv.contentView
        if Self.caretLog { Self.log("scroll caret \(sel.location) rect \(target) container \(textContainer?.size.width ?? -1) view \(frame.size) clip \(clip.bounds) edit \(caretByEdit) live \(inLiveResize)") }
        if caretByEdit, sel.location >= (string as NSString).length { target.size.height = max(target.height, bounds.maxY - target.minY) }
        let visible = clip.bounds
        var y = visible.minY
        if target.minY < visible.minY { y = target.minY } else if target.maxY > visible.maxY { y = target.maxY - visible.height }
        y = min(max(0, y), max(0, bounds.height - visible.height))
        if abs(y - visible.minY) > 0.01 {
            clip.scroll(to: NSPoint(x: visible.minX, y: y))
            sv.reflectScrolledClipView(clip)
        }
        return true
    }
    override func scrollRangeToVisible(_ range: NSRange) {
        if !scrollCaretIntoField(range) { super.scrollRangeToVisible(range) }
    }
    /// AppKit's caret scrolling after a key can come here too (with its own margin).
    override func scrollToVisible(_ rect: NSRect) -> Bool {
        if scrollCaretIntoField() { return true }
        return super.scrollToVisible(rect)
    }

    /// cmux: where the system emoji picker opens (screen coordinates), set by the emoji button
    /// (ChatController+Emoji.swift) just before it asks for the picker. The picker places itself at
    /// the first responder's `firstRect(forCharacterRange:)`; this field draws its own caret, and
    /// AppKit's rect for it was zero or off screen, so the picker opened at the screen's corner.
    /// One open only: the next selection change (the chosen emoji), key, modifier (Fn Fn
    /// dictation), marked text, click or loss of the keyboard clears it, and the field reports
    /// AppKit's rect again.
    var pickerAnchor: NSRect?
    override func flagsChanged(with event: NSEvent) {
        pickerAnchor = nil  // cmux
        super.flagsChanged(with: event)
    }
    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        if let pickerAnchor { actualRange?.pointee = range; return pickerAnchor }  // cmux
        return super.firstRect(forCharacterRange: range, actualRange: actualRange)
    }

    /// The pasteboard Paste reads (a check injects its own).
    var pasteboard: NSPasteboard = .general

    override func paste(_ sender: Any?) {
        let pb = pasteboard
        if onPastePasteboard(pb) {  // cmux: the words beside the attachments go in too
            if let text = pasteTextBesideAttachments(pb), !text.isEmpty { insertPlainText(text) }
            return
        }
        if let onPasteImage, pb.string(forType: .string) == nil, let img = NSImage(pasteboard: pb) { onPasteImage(img); return }  // cmux
        super.paste(sender)
    }

    /// cmux: Paste and Match Style (Edit menu, Cmd+Shift+V): the clipboard's
    /// plain text only, at the caret (replacing the selection), as its own undo
    /// step. Rich text, HTML, files and pictures never reach the host's intake.
    override func pasteAsPlainText(_ sender: Any?) {
        guard isEditable, let text = plainText(pasteboard), !text.isEmpty else { return }
        insertPlainText(text)
    }

    /// cmux: TEXT at the caret (replacing the selection) in the typing style, as its own undo step.
    private func insertPlainText(_ text: String) {
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: text), let storage = textStorage else { return }
        breakUndoCoalescing()
        storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: typingAttributes))
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        didChangeText()
        breakUndoCoalescing()
    }

    /// cmux: the plain text Paste and Match Style takes from a pasteboard (its
    /// `.string`; nil for a picture or a file alone). A check stubs it: the CI
    /// Macs' pasteboard server answers reads of a fresh private board inconsistently.
    var plainText: (NSPasteboard) -> String? = { $0.string(forType: .string) }

    /// cmux: Copy, Cut and a drag of a selection holding attachments write their words without
    /// the U+FFFC marks, then the attachments' files (ComposeSelectionCopy.swift); a selection of
    /// words alone keeps NSTextView's own.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let copy = ComposeSelectionCopy(file: draftAttachmentFile)
        guard let storage = textStorage, let pieces = copy.pieces(storage, ranges: selectedRanges.map(\.rangeValue)) else {
            return super.writeSelection(to: pboard, types: types)
        }
        pboard.clearContents()
        return pboard.writeObjects(copy.items(pieces))
    }

    // cmux: files and pictures dropped on the field go to the host's intake
    // (Home's type rule, as paste); text drags keep NSTextView's own handling.
    // cmux: the intake's answer depends only on the drag's pasteboard, so it is read once per drag
    // (its sequence number), not on every drag-over event: the drag server waits for each answer,
    // and each read is a round trip to the pasteboard server (DragWhileStreamingTests).
    private var dragAnswer: (sequence: Int, accepts: Bool)?
    private func takesDrag(_ sender: any NSDraggingInfo) -> Bool {
        if let a = dragAnswer, a.sequence == sender.draggingSequenceNumber { return a.accepts }
        let accepts = (acceptsDropPasteboard ?? acceptsPastePasteboard)(sender.draggingPasteboard)  // cmux
        dragAnswer = (sender.draggingSequenceNumber, accepts)
        return accepts
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragAnswer = nil
        let takes = takesDrag(sender)  // cmux
        onDropTargetChange(takes)  // cmux
        return takes ? .copy : super.draggingEntered(sender)  // cmux
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let takes = takesDrag(sender)  // cmux
        onDropTargetChange(takes)  // cmux: the host ignores a repeat
        return takes ? .copy : super.draggingUpdated(sender)  // cmux
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dragAnswer = nil
        onDropTargetChange(false)  // cmux
        super.draggingExited(sender)
    }
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dragAnswer = nil
        onDropTargetChange(false)  // cmux
        super.draggingEnded(sender)
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        takesDrag(sender) || super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let takes = takesDrag(sender)
        dragAnswer = nil
        onDropTargetChange(false)  // cmux
        if takes { return onDropPasteboard(sender.draggingPasteboard) }
        return super.performDragOperation(sender)
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
/// Messages' field is a UITextView, a scroll view: past `ComposeView.maxHeight` its text scrolls and
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
        view.onEndLiveResize = { [weak self] in
            self?.placeWaitingWidth()
            // A layout of the last drag event can still come while the window ends the resize (it
            // still reports one) and keep the width again: the next turn of the run loop places it.
            DispatchQueue.main.async { self?.placeWaitingWidth() }
        }
    }
    deinit { scrolled.map(NotificationCenter.default.removeObserver) }

    /// The field's frame whose width waits for the end of a live resize (nil: none waits).
    private(set) var widthWaiting: CGRect?
    /// Whether `place(frame)` may keep the field's width now (see `place`): it then moves the clip
    /// to the frame's origin and records the frame.
    private func deferWidth(to frame: CGRect) -> Bool {
        guard !placingWaitingWidth, clip.window?.inLiveResize == true, clip.frame.height == frame.height, view.string.isEmpty, !view.hasMarkedText(),
              view.userInterfaceLayoutDirection == .leftToRight else { return false }
        let style = view.typingAttributes[.paragraphStyle] as? NSParagraphStyle ?? view.defaultParagraphStyle
        if let style, style.baseWritingDirection == .rightToLeft || ![.left, .natural, .justified].contains(style.alignment) { return false }
        widthWaiting = frame
        if clip.frame.origin != frame.origin {
            clip.setFrameOrigin(frame.origin)
            view.updateCaret(reset: false)
        }
        return true
    }
    /// The end of the live resize: the waiting width now (the full `place`).
    func placeWaitingWidth() {
        guard let f = widthWaiting else { return }
        widthWaiting = nil
        // The window can still report a live resize while it ends.
        placingWaitingWidth = true
        place(f)
        placingWaitingWidth = false
    }
    private var placingWaitingWidth = false
    func insertText(_ s: String) { view.insertText(s, replacementRange: view.selectedRange()) }

    /// The clip at FRAME (host coordinates): the document is at least the clip's height, as wide
    /// as it; a size change keeps the caret line in view (a live resize rewraps the lines).
    func place(_ frame: CGRect) {
        guard clip.frame != frame else { return }
        // A live resize that changes only the field's width while the draft is empty: no pixel of
        // the empty field depends on its width (the caret stands at the left inset of an empty
        // left-to-right line; the placeholder is the compose bar's own layer), so the clip keeps its
        // width and the text view is not resized, rewrapped and redrawn at every width. The
        // width follows at the end of the resize, or at once when the draft or the field's
        // height changes. Text view resizes in a live resize were about a third of the app's
        // display-link misses above the empty-window floor (cx-3cb resize-drops, rig A/B).
        if deferWidth(to: frame) { return }
        widthWaiting = nil
        let rewrap = clip.frame.width != frame.width
        if FieldTextView.caretLog { FieldTextView.log("place \(frame) from \(clip.frame) view \(view.frame.size) container \(view.textContainer?.size.width ?? -1)") }
        defer { if FieldTextView.caretLog { FieldTextView.log("placed view \(view.frame.size) content \(scrollView.contentSize) container \(view.textContainer?.size.width ?? -1) clip \(scrollView.contentView.bounds)") } }
        clip.frame = frame
        let size = scrollView.contentSize
        view.minSize = NSSize(width: 0, height: size.height)
        if view.frame.width != size.width { view.setFrameSize(NSSize(width: size.width, height: view.frame.height)) }
        // A new width rewraps the lines: TextKit lays them out again lazily, after this scroll.
        // Laid out now, the document's height and the caret's line are the new ones when the
        // caret is scrolled into view (the last line stayed under the field after a narrowing).
        // The field sets its text container's width itself: with `widthTracksTextView` AppKit
        // left the container at the old width through a live resize (probe 2026-10-10, --caret-log:
        // the text view widened 311 -> 502 pt in a drag, its container stayed 308 pt until the
        // drag ended; lab run 05:19's narrow step showed the lines unwrapped at the narrow width
        // after the drag, its caret line under the field).
        let width = size.width - 2 * view.textContainerInset.width
        if let c = view.textContainer, c.size.width != width { c.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude) }
        if rewrap, let tlm = view.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
        view.sizeToFit()
        view.keepCaretInView()
        // The caret view is the clip's sibling: a move of the clip alone (a window height change)
        // does not reach the text view's frame or scroll, so the caret follows here. Without it the caret stayed where the clip was when the field took
        // focus (still gate 2026-10-11, --caret-log: the launch placed the clip at y 907, the
        // window's resize to 1041 pt moved it to 999, the caret stayed at 915, 92 pt above the
        // field, in the transcript; or hidden, when the focus came before the first layout).
        view.updateCaret(reset: false)
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
    /// The scale its images draw at: its window view's renderScale (MessagesWindowView.setRenderScale calls
    /// `rescale`; cx-3cb view-scale), `Fixture.renderScale` before it is in one.
    /// AppKit's own views (the text view, the glass) follow their window.
    var renderScale: CGFloat { labRenderScale }
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
    /// The field is empty because of a send (no character typed and no attachment since): Messages
    /// keeps it at `ComposeMetrics.emptyAfterSend` (30 pt), not the one-line height.
    private(set) var emptyAfterSend = false
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
    /// cmux: the field was placed or the draft changed (the send button, ComposeSendSlot).
    var onSlotChange: (() -> Void)?
    /// cmux: the trailing width the text leaves free: the send button's slot, wider while the voice
    /// input listens (its waveform, finish and mic buttons; ComposeVoiceControls.swift). A change
    /// lays the text out at the new width and fits the field's height to it at once.
    var trailingReserve: CGFloat = ComposeSendSlot.trailingReserve {
        didSet {
            guard trailingReserve != oldValue else { return }
            let old = fieldHeight
            fieldHeight = height(for: text, width: bounds.width)
            place(height: fieldHeight)
            if fieldHeight != old { onFieldJump?() }
        }
    }
    /// cmux: the voice input's mic button stands where Messages' waveform is drawn.
    var hidesWaveform = false { didSet { if hidesWaveform != oldValue { applyEmptyGlyphs() } } }
    /// cmux: the voice input's "Listening…" line stands where the placeholder is drawn.
    var hidesPlaceholder = false { didSet { if hidesPlaceholder != oldValue { applyEmptyGlyphs() } } }
    /// cmux: the placeholder and the waveform show only in an empty field, unless the voice input
    /// stands in for them.
    private func applyEmptyGlyphs() {
        let empty = text.isEmpty && chips.isEmpty
        CATransaction.begin(); CATransaction.setDisableActions(true)
        placeholderLayer.opacity = empty && !hidesPlaceholder ? 1 : 0
        waveLayer.opacity = empty && !hidesWaveform ? 1 : 0
        CATransaction.commit()
    }
    /// cmux: the attachments in the field (the send button shows for them too).
    var attachmentCount: Int { chips.count }

    static func height(lines: Int, chips: Bool) -> CGFloat { ComposeMetrics.height(lines: lines, chips: chips) }
    /// per view (several Home tabs), from this compose bar's width.
    // cmux: the text always leaves the trailing slot (the waveform's, then the send button's).
    var textWidth: CGFloat { ComposeView.fieldWidth(bounds.width) - 24 - trailingReserve }
    static func fieldWidth(_ windowWidth: CGFloat) -> CGFloat { 526 + windowWidth - Fixture.windowWidth }
    static let font = Fixture.bodyFont
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
    /// per view (several Home tabs): the draft's lines at the text width of a window WINDOWWIDTH pt
    /// wide, with this compose bar's own memo (no limit: the field's height stops at `maxHeight`,
    /// its text scrolls past it).
    func lines(_ text: String, windowWidth: CGFloat) -> Int {
        // One-entry memo: every compose update asks again for the same draft (a send asks for "").
        let w = ComposeView.fieldWidth(windowWidth) - 24 - trailingReserve  // cmux: the send button's slot (wider while dictating)
        // The empty field (every send and every commit after it) has its own entry: the one-entry
        // memo held the last typed draft, so each send typeset " " again.
        // Its one line (a space) does not depend on the width: a live resize's every width
        // typeset it again (cx-3cb resize-drops).
        if text.isEmpty, let e = emptyLinesMemo, e.0 == w || (e.1 == 1 && w >= ComposeView.emptyLineMinWidth) { return e.1 }
        if let m = linesMemo, m.text == text, m.width == w { return m.count }
        if text.isEmpty {
            let n = TextLayout.make(" ", runs: [], maxWidth: w, font: ComposeView.font).lines.count
            emptyLinesMemo = (w, n)
            return n
        }
        // cmux: typing at the end of the draft (each key's case) lays out only from the start of the
        // memo's second-to-last line: a greedy break before it cannot move when text is appended. The
        // cost follows the change, not the draft (perf-lead.md issue 5, typing-frame-bench.py).
        let u = text as NSString
        var keep = 0, from = 0
        if let m = linesMemo, m.width == w, u.length > (m.text as NSString).length, text.hasPrefix(m.text),
           let second = m.starts.dropLast().last {
            keep = m.starts.count - 2
            from = second
        }
        let tail = TextLayout.make(u.substring(from: from), runs: [], maxWidth: w, font: ComposeView.font).lines
        let starts = Array((linesMemo?.starts ?? []).prefix(keep)) + tail.map { $0.range.location + from }
        linesMemo = (text, w, starts.count, starts)
        return starts.count
    }
    /// The field's tallest text part. Real Messages (compose-e2e messages, 2026-10-10, 628 pt
    /// wide): the glass stops at the same height in a 940, 740 and 600 pt window (a fixed height,
    /// not a share of the window): 293.6 pt by the e2e's glass detector, which reads Messages'
    /// 1-line and 5-line fields 1.9 pt short (29.1 for 31, 93.1 for 95), so 295.5 pt, about 17.5
    /// lines (the 8-line limit was Catalyst's guess). Past it the text scrolls.
    static let maxHeight: CGFloat = 295.5
    /// The field's height for the draft in a window WIDTH pt wide (the attachment row on top).
    private func height(for text: String, width: CGFloat) -> CGFloat {
        if emptyAfterSend && text.isEmpty && chips.isEmpty { return ComposeMetrics.emptyAfterSend }
        // cmux: attachments in the text: the lines that hold them are as tall as their thumbnails.
        if !chips.isEmpty, let storage = textView.view.textStorage, storage.string == text {
            let extra = ComposeInlineText.extraHeight(storage, width: ComposeView.fieldWidth(width) - 24 - trailingReserve)
            return min(ComposeView.height(lines: 1, chips: false) + extra, ComposeView.maxHeight) + strip.height
        }
        return min(ComposeView.height(lines: lines(text, windowWidth: width), chips: false), ComposeView.maxHeight) + strip.height
    }
    /// cmux: the last draft's line count and where each of its lines starts (UTF-16), for the
    /// incremental layout of the next key.
    private var linesMemo: (text: String, width: CGFloat, count: Int, starts: [Int])?
    /// The empty draft's one line at any text width from this (a space is about 4 pt wide).
    static let emptyLineMinWidth: CGFloat = 20
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
    /// The space under the last line when the field scrolls (past `maxHeight`), scrolled to the end:
    /// real Messages, 20 pasted lines (compose-e2e messages, 2026-10-09): the caret 2.1 pt above
    /// the glass's bottom, its line 4.35 pt (unscrolled, 8.2 pt: the field's own margin). Below
    /// `maxHeight` the document (top inset, lines, this) is shorter than the field, so nothing
    /// scrolls and the text sits where it sat.
    static let textBottomInset: CGFloat = 4.35
    /// The field's scroll bar (an overlay scroller while the field scrolls). Off: Messages shows none
    /// (not in a trackpad scroll over the field either, same take).
    static let showsScroller = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        let none: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
        for l in [glass, placeholderLayer, waveLayer, chipsLayer, caret, textSnapshot, overlay, veil, rim, tint, plusLayer] {
            l.actions = none; l.contentsScale = renderScale
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
        inlineHover.install(on: tv)  // cmux: an inline attachment's remove button on hover
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
        // The container's width follows the field's width in `ComposeTextView.place`, not AppKit's
        // tracking (which lagged through a live resize).
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: ComposeView.fieldWidth(Metrics.current.width) - 24 - ComposeSendSlot.trailingReserve, height: CGFloat.greatestFiniteMagnitude)
        tv.layerContentsPlacement = .topLeft
        tv.layer?.masksToBounds = true
        tv.layer?.contentsGravity = .topLeft
        tv.layer?.contentsScale = renderScale
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
        tv.setAccessibilityIdentifier("cmux.home.composer")

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
        if placeholderScale != renderScale { renderPlaceholder() }
        // A new window width rewraps the draft: the field's height follows at once, as Messages'
        // (the window view lays the rows out on the new field top after this).
        let h = height(for: text, width: bounds.width)
        let jumped = h != fieldHeight
        fieldHeight = h
        place(height: fieldHeight)
        if jumped { onFieldJump?() }
    }

    /// The display scale changed: draw every image again at the new scale.
    func rescale() {
        for l in [glass, placeholderLayer, waveLayer, chipsLayer, caret, textSnapshot, overlay, veil, rim] { l.contentsScale = renderScale }
        textView.view.applyScale()
        // The drawn glass and buttons are hidden under AppKit's glass in the live window (nativeChrome): drawn when
        // shown (nativeChrome's didSet), as layoutSubviews does. They were a third of a display move's pass on main
        // (cx-3cb display-budget, Time Profiler: ComposeView.renderGlass).
        if !nativeChrome { renderGlass(); buttons.setNeedsDisplay() }
        renderPlaceholder()
        renderChips()
        // cmux: the caret follows the palette too (the bubble style, the theme, the accent).
        textView.view.recolorCaret()
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
        // cmux: the trailing slot stays free with text too (the send button), so the first character does not rewrap.
        return CGRect(x: f.minX + 12, y: f.minY + chipH, width: f.width - 24 - trailingReserve, height: f.height - chipH)
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
        waveLayer.frame = CGRect(x: f.maxX - 30, y: ComposeView.waveY(f), width: 24, height: 30)
        chipsLayer.frame = CGRect(x: f.minX, y: f.minY, width: f.width, height: max(1, strip.height))
        strip.update(stripChips, width: f.width, scale: renderScale)
        textSnapshot.frame = textFrame(height: h)
        CATransaction.commit()
        textView.place(textFrame(height: h))
        onSlotChange?()  // cmux: the send button follows the field
    }

    /// The audio glyph's layer top for the field F: centred in the field, as Messages' (its glyph
    /// centre 1014.5 pt in the 31 pt field, 1015.0 in the 30 pt field after a send, macOS 27 and 26).
    /// It is placed at once on a send, not animated with the field: in send-2line-take2 Messages'
    /// glyph shows from +0.2 s at 1014.4-1015.0 pt while the field still shrinks.
    static func waveY(_ f: CGRect) -> CGFloat { f.midY - 14.5 }

    /// Glass field image: top and bottom rims are fixed, the middle stretches.
    private func renderGlass() {
        let w = ComposeView.fieldWidth(bounds.width)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = renderScale
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
        fmt.scale = renderScale
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
    /// The light or dark appearance changed (WindowView.setLightAppearance): the placeholder and the waveform
    /// are drawn again in its ink.
    func appearanceChanged() { renderPlaceholder() }

    private func renderPlaceholder() {
        placeholderScale = renderScale
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = renderScale
        fmt.opaque = false
        let ph = placeholder
        placeholderLayer.contents = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 30), format: fmt).image { ctx in
            TextDraw.line(ph, font: ComposeView.font, color: Fixture.placeholder, x: 12, baseline: ComposeView.firstBaseline, in: ctx.cgContext)
        }.cgImage
        placeholderLayer.contentsScale = fmt.scale
        waveLayer.contents = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 30), format: fmt).image { _ in
            Fixture.waveform.setFill()  // cmux: themed (with the placeholder above); the see-through ink without a theme
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
        strip.update(stripChips, width: ComposeView.fieldWidth(bounds.width), scale: renderScale)
    }

    // cmux: attachments sit in the field's text at the caret (Draft+InlineMarks.swift), not in a
    // strip above it; the strip stays empty.
    private var stripChips: [Attachment] { [] }
    /// The field's inline attachments by id (made once each).
    private(set) var inlineAttachments: [ID: ComposeInlineAttachment] = [:]
    /// cmux: the remove button over the inline attachment under the pointer.
    let inlineHover = ComposeInlineRemoveHover()

    /// The remove button of an inline attachment: its mark leaves the text as an edit, so the
    /// draft follows through the text view's own change path (`textDidChange`).
    func removeInline(_ id: ID) {
        let tv = textView.view
        guard let storage = tv.textStorage else { return }
        var range: NSRange?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { v, r, stop in
            if (v as? ComposeInlineAttachment)?.attachmentID == id { range = r; stop.pointee = true }
        }
        guard let range, tv.shouldChangeText(in: range, replacementString: "") else { return }
        storage.replaceCharacters(in: range, with: "")
        tv.didChangeText()
    }

    /// Just after the mark of the newest attachment that is in the draft D and not in BEFORE
    /// (an attachment came in: the caret follows it, as after typing a character); nil when none came in.
    static func addedMark(_ d: Draft, before: [Attachment]) -> Int? {
        let old = Set(before.map(\.id))
        guard let k = d.attachments.lastIndex(where: { !old.contains($0.id) }) else { return nil }
        let marks = Draft.markOffsets(d.text)
        guard marks.count == d.attachments.count, let at = marks[checked: k] else { return nil }
        return at + 1
    }

    /// The caret after the field's text was built again: just after a mark that came in (an
    /// attachment entered at the caret), else where it was (clamped).
    static func caretAfterRebuild(old: NSString, new: NSString, selection: NSRange, added: Int? = nil) -> NSRange {
        if let added, added <= new.length { return NSRange(location: added, length: 0) }
        if new.length == old.length + 1 {
            var p = 0
            while p < old.length, old.character(at: p) == new.character(at: p) { p += 1 }
            if new.character(at: p) == 0xFFFC, new.substring(from: p + 1) == old.substring(from: p) {
                return NSRange(location: p + 1, length: 0)
            }
        }
        let loc = min(selection.location, new.length)
        return NSRange(location: loc, length: min(selection.length, new.length - loc))
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
        let hadDraft = !text.isEmpty || !chips.isEmpty
        let tv = textView.view
        // cmux: attachments are in the text (Draft+InlineMarks.swift): a new or changed attachment
        // builds the field's text again too.
        if tv.string != d.text || d.attachments != chips {
            // Never replace text that holds marked (IME) text: the input
            // method owns it until it commits.
            if !tv.hasMarkedText() {
                let old = tv.string as NSString, sel = tv.selectedRange()
                tv.textStorage?.setAttributedString(ComposeInlineText.build(d.text, attachments: d.attachments, cache: &inlineAttachments,
                                                                            scale: renderScale, onRemove: { [weak self] in self?.removeInline($0) }))
                tv.typingAttributes = ComposeInlineText.attributes(inline: !d.attachments.isEmpty)
                inlineHover.hide()  // cmux: the attachments moved; the pointer shows the button again
                tv.setSelectedRange(ComposeView.caretAfterRebuild(old: old, new: tv.string as NSString, selection: sel,
                                                                  added: ComposeView.addedMark(d, before: chips)))
                if !DeferredSpellChecker.useAppKit { tv.spell.textDidChange() }
            }
        }
        let newPlaceholder = state.ui.openThread != nil ? ComposeView.placeholders.reply : ComposeView.placeholders.field
        if newPlaceholder != placeholder { placeholder = newPlaceholder; renderPlaceholder(); tv.setAccessibilityLabel(placeholder) }
        // Messages changes the field's height at once for an attachment (no in-between frame at
        // 120 Hz, compose-attach-image paste take) and while typing (field-focus-type-take1 and
        // compose-e2e: one frame, the transcript on the same frame); only a send animates it.
        let attachmentsChanged = d.attachments != chips
        if attachmentsChanged { chips = d.attachments; renderChips(); onAttachmentsChanged?() }
        text = d.text
        // Only a send that took a draft (a rejected send is not committed: Store.apply).
        if send && hadDraft { emptyAfterSend = d.text.isEmpty && d.attachments.isEmpty }
        else if !d.text.isEmpty || !d.attachments.isEmpty { emptyAfterSend = false }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // With an attachment Messages shows neither the placeholder nor the audio glyph
        // (compose-attach-image stills).
        applyEmptyGlyphs()  // cmux: the voice input hides them (`hidesWaveform`, `hidesPlaceholder`)
        CATransaction.commit()
        let h = height(for: d.text, width: bounds.width)
        let old = fieldHeight
        fieldHeight = h
        if attachmentsChanged || placed.map({ $0.0 != h || $0.1 != text.isEmpty || $0.2 != strip.height || $0.3 != bounds.size }) ?? true {
            place(height: h)
        }
        if h != old && !send {
            onFieldJump?()
        } else if h != old {
            let e = Springs.fieldTop
            onFieldResize?(old, h, e, begin)
            Animate.scalar(glass, "bounds.size.height", from: Double(old), to: Double(h), e, begin: begin)
            for l in [veil, rim, tint] { Animate.scalar(l, "bounds.size.height", from: Double(old), to: Double(h), e, begin: begin) }
            let dTop = Double(h - old)
            // The capture caret rides with the placeholder (Fixture.SendCaret).
            for l in [placeholderLayer, chipsLayer, caret] {
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
        onSlotChange?()  // cmux: the send button follows the draft
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
        // The part of the document in the field (all of it up to `maxHeight`).
        let shown = tv.visibleRect.isEmpty ? tv.bounds : tv.visibleRect
        let size = shown.size
        guard size.width > 0, size.height > 0, var rep = tv.bitmapImageRepForCachingDisplay(in: shown) else { return }
        // AppKit sizes the cache for the main screen when the view has no window (1x on a Mac
        // whose main display is 1x); the snapshot is drawn at the scale of the tree it goes into.
        let scale = tv.window.map { $0.backingScaleFactor * tv.enclosingContentZoom } ?? renderScale  // cmux: a zoomed Chief chat
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
        var alpha = 1.0, color: UIColor = Fixture.caret
        if let s = sinceSend, let st = Fixture.SendCaret.state(s) { alpha = st.alpha; color = st.color }
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
        // Messages' caret: 1 x 17 pt, its top 7 pt under the field top (13.25 above the first baseline).
        caret.frame = CGRect(x: cx.px, y: base - 13.25 + row * 16, width: 1, height: 17)
        caret.backgroundColor = color.cgColor
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
