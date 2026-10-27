#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its text input.
import CoreGraphics

/// cmux's half of the page's `NSTextInputClient`, with no AppKit in it: the
/// state the host pushed, the input method's marked text, and the rules that
/// turn one key's input method calls into key frames and ops
/// (``ChromiumHostPageView`` adds the AppKit half). The rules are Chrome's
/// `-[RenderWidgetHostViewCocoa keyEvent:wasKeyEquivalent:]`
/// (content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm). Nothing
/// here waits for the host: every answer comes from what it already pushed.
nonisolated struct ChromiumHostTextInput: Sendable {
    /// What one input method call or key sends, in order.
    enum Output: Equatable, Sendable {
        /// To the input ring.
        case key(ChromiumHostFrame)
        /// To the ordered stream after the key frames before it.
        case op(ChromiumHostTextInputOp)
    }

    /// What one ``apply(_:)`` needs from the input context.
    struct Applied: Equatable, Sendable {
        /// The field lost its composition: the input method drops its marked text.
        var discardMarkedText = false
        /// The composition moved on the page: the input method asks for its rects again.
        var invalidateCharacterCoordinates = false
    }

    /// Counts for `debug.chromium_host` (``report``). There is no count of requests that ask
    /// the host and wait: no such path exists, which code reading checks (p01-process.md 7).
    struct Stats: Equatable, Sendable {
        /// `firstRectForCharacterRange` answers from pushed rects.
        var firstRectAnswers = 0
        /// Ranges the pushed state does not cover: answered with the caret rect.
        var firstRectMisses = 0
        /// `characterIndexForPoint` points off every pushed rect: answered NSNotFound.
        var characterIndexMisses = 0

        /// The counts under their `debug.chromium_host` names.
        var report: [String: Int] {
            ["ime_first_rect_answers": firstRectAnswers, "ime_first_rect_misses": firstRectMisses,
             "ime_character_index_misses": characterIndexMisses]
        }
    }

    /// A key frame's v3 (`ChromiumHostFrame`): how the host sends the key.
    enum KeyMark: Int32, Sendable {
        /// A key down and the frame's character (`ch`) when it has one.
        case plain = 0
        /// An input method took the key: a key down as VKEY_PROCESSKEY (0xE5,
        /// skip_if_unhandled) and no character, so pages see keyCode 229
        /// while text is being composed, as on Windows. On a key up: the up
        /// that balances that process key down before the real key follows it.
        case inputMethod = 1
        /// The character only (`ch`), after an input method's turn (Chrome's kChar).
        case characterOnly = 2
    }

    /// The input method calls inside one key down.
    private struct Turn: Sendable {
        var hadMarkedText: Bool
        var inserted: [UInt16] = []
        var replacement: Range<Int>?
        var unmarkCalled = false
        var hasEditCommands = false
        var editCommands: [String] = []
    }

    /// The longest composition sent, 4 KiB of UTF-16: with a clause per unit
    /// its kIme frame stays under ``ChromiumHostFrame/maxPayload``, so the
    /// host never refuses it. A longer marked text keeps its first units.
    static let maxCompositionUnits = 2048
    /// The longest text one commit op carries (its payload is the text alone);
    /// a longer insert goes as consecutive commits, the first with the replacement.
    static let maxCommitUnits = ChromiumHostFrame.maxPayload / 2

    private(set) var state = ChromiumHostTextInputState()
    /// The input method's marked text (UTF-16).
    private(set) var markedText: [UInt16] = []
    /// The selection inside ``markedText``.
    private(set) var markedSelection = 0..<0
    private(set) var clauses: [ChromiumHostCompositionClause] = []
    private(set) var stats = Stats()
    private var turn: Turn?
    /// A composition op went to the host and no push has shown a composition since: a push
    /// without one may predate the op, so it does not mean the page dropped the composition.
    private var compositionInFlight = false

    var hasMarkedText: Bool { !markedText.isEmpty }

    /// The marked text's place in the field: where the host put the
    /// composition (or the selection, before the host has pushed it), as long
    /// as the input method's text; nil without marked text.
    var markedRange: Range<Int>? {
        guard hasMarkedText else { return nil }
        let start = state.composition?.lowerBound ?? state.selection?.lowerBound ?? 0
        return start..<(start + markedText.count)
    }

    // MARK: Pushed state

    /// Takes a TEXT_INPUT_STATE push. The input method's composition ends here
    /// too when the page has none left for it: focus left every field that
    /// takes an input method (none, a password field), focus moved to a field
    /// of another type, or the page dropped its composition (a script moved
    /// focus or changed the field) while no composition op of cmux is on its way.
    mutating func apply(_ pushed: ChromiumHostTextInputState) -> Applied {
        let previous = state
        state = pushed
        if pushed.composition != nil { compositionInFlight = false }
        var applied = Applied()
        guard hasMarkedText else { return applied }
        let pageDropped = pushed.composition == nil && !compositionInFlight
        if !pushed.type.takesInputMethod || pushed.type != previous.type || pageDropped {
            applied.discardMarkedText = cancelComposition()
        } else if previous.compositionRects != pushed.compositionRects || previous.caretRect != pushed.caretRect {
            applied.invalidateCharacterCoordinates = true
        }
        return applied
    }

    // MARK: Key turns

    /// A key down goes to the input method next (`interpretKeyEvents`).
    mutating func beginKey() {
        turn = Turn(hadMarkedText: hasMarkedText)
    }

    /// The input method is done with the key down that `key` describes: the
    /// key frames and ops that send it, in Chrome's order (process key down,
    /// commit, composition, the process key's up and the delayed key, the character).
    mutating func endKey(_ key: ChromiumHostFrame, controlOrCommand: Bool) -> [Output] {
        guard let turn else { return [.key(key)] }
        self.turn = nil
        let marked = hasMarkedText
        let composing = marked || turn.hadMarkedText
        var outputs: [Output] = []
        // The input method took the key: pages see a process key. The real key
        // follows the composition when the input method also chose a command
        // and left no marked text (Korean Return ends the composition and still
        // makes a new line): Chrome's `_hasEditCommands && !_hasMarkedText`.
        let taken = composing || turn.inserted.count > 1
        if taken { outputs.append(.key(Self.marking(key, .inputMethod, ch: 0))) }
        let delayed = taken && turn.hasEditCommands && !marked
        var committed = false
        if turn.inserted.count > (composing ? 0 : 1) {
            outputs += Self.commits(turn.inserted, replacement: nil)
            committed = true
        }
        if marked {
            outputs.append(.op(.setComposition(text: String(decoding: markedText, as: UTF16.self), clauses: clauses,
                                               selection: markedSelection, replacement: turn.replacement)))
            compositionInFlight = true
        } else if turn.hadMarkedText, !committed {
            outputs.append(.op(turn.unmarkCalled ? .finishComposing : .cancelComposition))
        }
        let ch = Self.character(of: key, turn: turn, marked: marked, committed: committed, delayed: delayed,
                                controlOrCommand: controlOrCommand)
        if delayed {
            // The process key down's up first, so the page's key state balances.
            var up = Self.marking(key, .inputMethod, ch: 0)
            up.v[0] = 1
            outputs.append(.key(up))
        }
        if !taken || delayed {
            if !turn.editCommands.isEmpty { outputs.append(.op(.keyCommands(turn.editCommands))) }
            outputs.append(.key(Self.marking(key, .plain, ch: ch)))
        } else if ch != 0 {
            outputs.append(.key(Self.marking(key, .characterOnly, ch: ch)))
        }
        return outputs
    }

    /// The character a key sends after its turn, 0 for none: the one typed
    /// character, or, when AppKit inserts nothing for the key (Control or
    /// Command down, or a key bound to an insert command such as Return or
    /// Tab), the key's own character.
    private static func character(of key: ChromiumHostFrame, turn: Turn, marked: Bool, committed: Bool, delayed: Bool,
                                  controlOrCommand: Bool) -> UInt16 {
        guard !marked else { return 0 }
        if !committed, turn.inserted.count == 1 { return turn.inserted[0] }
        let insertCommandOnly = turn.hasEditCommands && turn.editCommands.isEmpty
        if !committed || delayed, key.ch != 0, controlOrCommand || insertCommandOnly { return key.ch }
        return 0
    }

    /// The character a key frame carries for `characters`: its one UTF-16
    /// unit, or 0. A character of more units (outside the BMP) never goes as
    /// half of a surrogate pair: the input method's insert commits it whole,
    /// as Chrome inserts non-BMP characters as text
    /// (`-[RenderWidgetHostViewCocoa keyEvent:wasKeyEquivalent:]`).
    static func keyCharacter(_ characters: String?) -> UInt16 {
        guard let units = characters?.utf16, units.count == 1, let unit = units.first,
              !UTF16.isLeadSurrogate(unit), !UTF16.isTrailSurrogate(unit) else { return 0 }
        return unit
    }

    /// `units` as commit ops of at most ``maxCommitUnits`` each, never
    /// splitting a surrogate pair; only the first replaces `replacement`.
    private static func commits(_ units: [UInt16], replacement: Range<Int>?) -> [Output] {
        let ends = Array(sequence(first: boundary(units, at: min(maxCommitUnits, units.count))) { end in
            end < units.count ? boundary(units, at: min(end + maxCommitUnits, units.count)) : nil
        })
        return zip([0] + ends.dropLast(), ends).map { (start: Int, end: Int) -> Output in
            .op(.commitText(String(decoding: units[start..<end], as: UTF16.self),
                            replacement: start == 0 ? replacement : nil))
        }
    }

    /// `index`, moved back one unit when it falls inside a surrogate pair.
    private static func boundary(_ units: [UInt16], at index: Int) -> Int {
        guard index > 0, index < units.count, UTF16.isTrailSurrogate(units[index]),
              UTF16.isLeadSurrogate(units[index - 1]) else { return index }
        return index - 1
    }

    private static func marking(_ key: ChromiumHostFrame, _ mark: KeyMark, ch: UInt16) -> ChromiumHostFrame {
        var frame = key
        frame.v[3] = mark.rawValue
        frame.ch = ch
        return frame
    }

    // MARK: Input method calls

    /// `setMarkedText`: inside a key turn the key's end sends it; outside one
    /// (a click in the candidate window, a layout switch) it goes now.
    /// Marked text over ``maxCompositionUnits`` keeps its first units here and
    /// on the host alike, so ``markedRange`` and the page's composition agree.
    mutating func setMarkedText(_ text: String, clauses: [ChromiumHostCompositionClause], selection: Range<Int>,
                                replacement: Range<Int>?) -> [Output] {
        var units = Array(text.utf16)
        if units.count > Self.maxCompositionUnits {
            units.removeSubrange(Self.boundary(units, at: Self.maxCompositionUnits)...)
        }
        let length = units.count
        func clamped(_ range: Range<Int>) -> Range<Int> {
            min(max(range.lowerBound, 0), length)..<min(max(range.upperBound, 0), length)
        }
        markedText = units
        markedSelection = clamped(selection)
        self.clauses = clauses.compactMap { clause in
            var kept = clause
            kept.range = clamped(clause.range)
            return kept.range.isEmpty ? nil : kept
        }
        if turn != nil {
            turn?.replacement = replacement
            return []
        }
        compositionInFlight = !units.isEmpty
        return [.op(.setComposition(text: String(decoding: units, as: UTF16.self), clauses: self.clauses,
                                    selection: markedSelection, replacement: replacement))]
    }

    /// `insertText`: typed text waits for the key's end; text with a
    /// replacement range, or from outside a key (the emoji picker,
    /// dictation, a candidate click), commits now.
    mutating func insertText(_ text: String, replacement: Range<Int>?) -> [Output] {
        clearMarkedText()
        if turn != nil, replacement == nil {
            turn?.inserted += Array(text.utf16)
            return []
        }
        return Self.commits(Array(text.utf16), replacement: replacement)
    }

    /// `unmarkText`: keeps the composition's text and ends it.
    mutating func unmarkText() -> [Output] {
        let had = hasMarkedText
        clearMarkedText()
        if turn != nil {
            turn?.unmarkCalled = true
            return []
        }
        return had ? [.op(.finishComposing)] : []
    }

    /// `doCommandBySelector` with the selector's name ("insertNewline:").
    /// Inside a key turn the command goes with the key, except insert
    /// commands, which the key's own character carries (Chrome: a Tab bound
    /// to insertTab: must move focus, not insert a tab); outside one it runs now.
    mutating func doCommand(_ selector: String) -> [Output] {
        guard selector != "noop:" else { return [] }
        let command = Self.editCommand(selector)
        guard turn != nil else { return [.op(.editCommand(command))] }
        turn?.hasEditCommands = true
        if !command.lowercased().hasPrefix("insert") { turn?.editCommands.append(command) }
        return []
    }

    /// "insertNewline:" -> "InsertNewline", the edit command names Blink knows.
    static func editCommand(_ selector: String) -> String {
        let name = selector.hasSuffix(":") ? String(selector.dropLast()) : selector
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Drops the composition here only, when the page already dropped its own
    /// (blur, focus out of every field). True when there was one: the input
    /// method must discard its marked text too.
    mutating func cancelComposition() -> Bool {
        guard hasMarkedText else { return false }
        clearMarkedText()
        return true
    }

    /// Keeps the composition's text and ends it (a click in the page while
    /// composing: the caret must not move with a composition open).
    mutating func finishComposition() -> [Output] {
        guard hasMarkedText else { return [] }
        clearMarkedText()
        return [.op(.finishComposing)]
    }

    private mutating func clearMarkedText() {
        markedText = []
        markedSelection = 0..<0
        clauses = []
        compositionInFlight = false
    }

    // MARK: Geometry

    /// ``ChromiumHostTextInputState/firstRect(for:)``, counted; a range the
    /// pushed state does not cover gets the caret rect, so a candidate window
    /// still opens beside the caret.
    mutating func firstRect(for requested: Range<Int>) -> (rect: CGRect, actual: Range<Int>) {
        if let found = state.firstRect(for: requested) {
            stats.firstRectAnswers += 1
            return found
        }
        stats.firstRectMisses += 1
        return (state.caretRect, requested)
    }

    /// ``ChromiumHostTextInputState/characterIndex(at:)``, counted.
    mutating func characterIndex(at point: CGPoint) -> Int? {
        let index = state.characterIndex(at: point)
        if index == nil { stats.characterIndexMisses += 1 }
        return index
    }

    /// ``ChromiumHostTextInputState/substring(of:markedText:)`` with this marked text.
    func substring(of requested: Range<Int>) -> (text: String, actual: Range<Int>)? {
        state.substring(of: requested, markedText: markedText)
    }
}
#endif
