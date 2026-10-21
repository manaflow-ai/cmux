// cmux: the message box's dictation: where the words go and what Esc and Return do. Not a vendored file.
import AppKit

/// Where a voice session's words sit in the field: at the caret the session began at, after a
/// space when the text before it ends in a word and before one when a word follows. Each update replaces the words shown so far
/// (a live guess can change), so the text around them (and any attachment in it) is untouched.
struct ComposeVoiceSplice: Equatable {
    /// The UTF-16 offset the words start at.
    let location: Int
    /// A space goes before the words (the caret was right after a word).
    let leadingSpace: Bool
    /// A space goes after the words (a word starts right at the caret).
    let trailingSpace: Bool
    /// What the field shows for the session now (the spaces and the words).
    private(set) var shown = ""
    /// The UTF-16 length of ``shown``.
    var length: Int { (shown as NSString).length }

    init(text: NSString, caret: Int) {
        let at = min(max(0, caret), text.length)
        location = at
        if at > 0, let scalar = Unicode.Scalar(text.character(at: at - 1)) {
            leadingSpace = !CharacterSet.whitespacesAndNewlines.contains(scalar)
        } else {
            leadingSpace = false
        }
        if at < text.length, let scalar = Unicode.Scalar(text.character(at: at)) {
            trailingSpace = CharacterSet.alphanumerics.contains(scalar)
        } else {
            trailingSpace = false
        }
    }

    /// What the field shows for `words`: nothing for no words, else the words between the spaces.
    func piece(_ words: String) -> String {
        words.isEmpty ? "" : (leadingSpace ? " " : "") + words + (trailingSpace ? " " : "")
    }

    /// The field's range the session's piece takes now.
    var range: NSRange { NSRange(location: location, length: length) }

    /// Replaces the shown piece with `words`: the range to replace and its new text.
    mutating func replace(with words: String) -> (range: NSRange, text: String) {
        let old = range
        let text = piece(words)
        shown = text
        return (old, text)
    }
}

/// One message box's voice session, as the field shows it. The host's engine (``HomeVoiceInput``)
/// listens; this puts its words at the caret while it listens (each update replaces the last),
/// commits them as one undo step when the session ends, and takes them out on Esc, leaving the
/// draft as it was. A key the person types while it listens keeps the words where they are and
/// stops the session: later words would land in the middle of their typing.
final class ComposeVoice {
    weak var controller: ChatController?
    /// The host's engine; nil: no mic button (the field shows Messages' drawn waveform).
    weak var input: (any HomeVoiceInput)? {
        didSet { controller?.voiceChromeChanged(animated: false) }
    }
    private(set) var phase: HomeVoicePhase = .idle
    /// The input level, 0...1, while listening.
    private(set) var level: Float = 0
    private(set) var splice: ComposeVoiceSplice?
    /// The field edit in progress is the session's own (not the person typing).
    private(set) var applying = false
    /// The person typed: this session's later words are dropped.
    private var detached = false
    /// Watches the field's undo stack while words show (Edit > Undo comes from the menu, not a key).
    private var undoWatch: NSObjectProtocol?

    /// A session runs (starting, listening or finalizing).
    var isActive: Bool { phase != .idle }

    init(controller: ChatController) { self.controller = controller }

    deinit {
        if let undoWatch { NotificationCenter.default.removeObserver(undoWatch) }
    }

    /// The mic button.
    func toggle() {
        guard let input else { return }
        if !isActive { controller?.focusCompose() }
        input.toggleVoice()
    }

    /// The return-key button or Return: stop and keep the words. True when a session ran.
    @discardableResult func finish() -> Bool {
        guard isActive else { return false }
        input?.finishVoice()
        return true
    }

    /// Esc: stop and take the words out. True when a session ran. Once finishing (Return or the
    /// finish button kept the words), Esc leaves them and goes on to its usual job (stopping an agent).
    @discardableResult func cancel() -> Bool {
        guard isActive, phase != .finalizing else { return false }
        input?.cancelVoice()
        return true
    }

    /// A change from the host's engine.
    func apply(_ update: HomeVoiceUpdate) {
        let wasActive = isActive, oldPhase = phase
        phase = update.phase
        level = update.phase == .listening ? max(0, min(1, update.level)) : 0
        if update.phase == .idle {
            end(update)
        } else {
            if !wasActive { begin() }
            if !detached { show(update.text) }
        }
        // A level or words in the same phase: the words already moved the field; only the bars follow.
        if phase == oldPhase, isActive { controller?.voiceLevelChanged() } else { controller?.voiceChromeChanged(animated: wasActive != isActive) }
    }

    /// The field's text changed: true when it was the person, not the session.
    func fieldChanged() {
        guard isActive, !applying, splice != nil else { return }
        detached = true
        splice = nil
        input?.finishVoice()
    }

    private func begin() {
        detached = false
        guard let field = controller?.demo?.compose.textView.view else { splice = nil; return }
        let sel = field.selectedRange()
        splice = ComposeVoiceSplice(text: field.string as NSString, caret: sel.location + sel.length)
        // The shown words register no undo, so the stack's ranges are the draft's without them: an
        // undo first takes the words out (the draft as it was) and stops the session.
        if let undo = field.undoManager {
            undoWatch = NotificationCenter.default.addObserver(
                forName: .NSUndoManagerWillUndoChange, object: undo, queue: nil
            ) { [weak self] _ in self?.undoDuringSession() }
        }
    }

    private func undoDuringSession() {
        guard isActive, !detached, var splice, let field = controller?.demo?.compose.textView.view else { return }
        if isShowing(splice, in: field) {
            let out = splice.replace(with: "")
            edit(field, out.range, out.text, caret: splice.location)
        }
        detached = true
        self.splice = nil
        input?.cancelVoice()
    }

    private func end(_ update: HomeVoiceUpdate) {
        defer {
            splice = nil
            detached = false
            if let undoWatch { NotificationCenter.default.removeObserver(undoWatch) }
            undoWatch = nil
        }
        guard !detached, var splice, let field = controller?.demo?.compose.textView.view else { return }
        // Something else rebuilt the field (an attachment landed): the words stay where they are.
        guard isShowing(splice, in: field) else { return }
        // The shown piece leaves without an undo step; a commit puts the final words back as one.
        let out = splice.replace(with: "")
        edit(field, out.range, out.text, caret: splice.location)
        guard !update.cancelled else { return }
        let words = splice.piece(update.text)
        guard !words.isEmpty else { return }
        field.breakUndoCoalescing()
        field.insertText(words, replacementRange: NSRange(location: splice.location, length: 0))
        field.breakUndoCoalescing()
    }

    private func show(_ words: String) {
        guard var splice, let field = controller?.demo?.compose.textView.view else { return }
        // The field changed under the words without a keystroke (an attachment rebuilt it): the
        // range is stale, so the session lets go and the words stay as they are.
        guard isShowing(splice, in: field) else {
            detached = true
            self.splice = nil
            input?.finishVoice()
            return
        }
        guard splice.piece(words) != splice.shown else { return }
        let change = splice.replace(with: words)
        self.splice = splice
        edit(field, change.range, change.text, caret: splice.location + splice.length)
    }

    /// A field edit that registers no undo (the session's words come and go; only the commit is one step).
    private func edit(_ field: FieldTextView, _ range: NSRange, _ text: String, caret: Int) {
        guard let storage = field.textStorage else { return }
        let r = clamped(range, in: field)
        applying = true
        defer { applying = false }
        storage.replaceCharacters(in: r, with: NSAttributedString(string: text, attributes: field.typingAttributes))
        field.setSelectedRange(NSRange(location: min(caret, storage.length), length: 0))
        field.didChangeText()
    }

    /// The field still shows the session's piece where the splice says.
    private func isShowing(_ splice: ComposeVoiceSplice, in field: FieldTextView) -> Bool {
        let text = field.string as NSString
        guard NSMaxRange(splice.range) <= text.length else { return false }
        return text.substring(with: splice.range) == splice.shown
    }

    private func clamped(_ range: NSRange, in field: FieldTextView) -> NSRange {
        let n = (field.string as NSString).length
        let lo = min(range.location, n)
        return NSRange(location: lo, length: min(range.length, n - lo))
    }
}
