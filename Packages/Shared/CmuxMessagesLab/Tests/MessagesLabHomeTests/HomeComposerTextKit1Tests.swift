import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The Home composer field is TextKit 1 (`ComposeTextView`, NSTextView+TextKit1Lines.swift): a key costs
/// its line, not its paragraph (HomeComposerKeyCostTests). What TextKit 2 gave the field for free must
/// still hold (a1212, 2026-11-20): the field stays TextKit 1 once shown and focused, the caret it draws
/// itself sits where TextKit 2 put it (right-to-left text and emoji included), input-method marked text
/// in a long draft commits whole, typing undoes and redoes as one group, VoiceOver reads the text and
/// its lines, and Writing Tools and the spelling marks keep their settings. The real Home view over the
/// mock owner, in an offscreen window.
@MainActor @Suite(.serialized) struct HomeComposerTextKit1Tests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let conversation = ConversationID("conv_chief")

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    @MainActor private struct Rig {
        let store: HomeStore
        let window: NSWindow
        let view: MessagesLabHomeView
        var field: FieldTextView { view.controller.demo!.compose.textView.view }
        func frame() {
            view.projection.refresh()
            window.contentView?.layoutSubtreeIfNeeded()
            view.controller.host.layoutSubtreeIfNeeded()
            CATransaction.flush()
        }
        func close() { view.stop(); window.close(); store.stop() }
    }

    private func rig() async throws -> Rig {
        let options = MockHomeSource.Options(chiefHistory: 12, latency: .zero, replyDelay: .seconds(3600))
        let store = HomeStore(source: MockHomeSource(options: options))
        store.start()
        await until { store.me != nil && store.isOnline }
        await store.open(Self.conversation)
        await until { !store.transcript(for: Self.conversation).isEmpty }
        let me = try #require(store.me?.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake())
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let r = Rig(store: store, window: window, view: view)
        r.frame()
        return r
    }

    /// The draft the store holds (what a send takes and a relaunch restores).
    private func draft(_ r: Rig) -> String { r.view.controller.store?.state.ui.draft.text ?? "" }

    // MARK: TextKit 1 stays on

    /// TextKit 2 comes back only through code (a field made `usingTextLayoutManager: true` again, a
    /// replaced text container): AppKit never switches a TextKit 1 view to TextKit 2 by itself, and the
    /// key cost's gain goes with it silently. Shown, focused, typed in, read by accessibility and
    /// rewrapped at a new width, the field is still TextKit 1.
    @Test func theFieldStaysTextKit1OnceShownFocusedAndTypedIn() async throws {
        let r = try await rig()
        defer { r.close() }
        r.window.makeFirstResponder(r.field)
        r.field.insertText("the chief reads your note", replacementRange: r.field.selectedRange())
        _ = r.field.accessibilityValue()
        _ = r.field.accessibilityNumberOfCharacters()
        r.frame()
        r.window.setContentSize(NSSize(width: 520, height: 900))
        r.view.frame = NSRect(x: 0, y: 0, width: 520, height: 900)
        r.frame()
        r.window.displayIfNeeded()
        #expect(r.field.textLayoutManager == nil, "the composer field switched to TextKit 2")
        #expect(r.field.layoutManager != nil && r.field.textContainer?.layoutManager != nil, "the composer field lost its TextKit 1 layout manager")
    }

    // MARK: The caret, against TextKit 2's

    /// A TextKit 2 field with the composer field's text settings: the oracle for the caret's line.
    private func textKit2Twin(of field: FieldTextView, width: CGFloat) -> NSTextView {
        let twin = NSTextView(usingTextLayoutManager: true)
        twin.isRichText = false
        twin.font = field.font
        twin.textContainer?.lineFragmentPadding = field.textContainer?.lineFragmentPadding ?? 0
        twin.textContainer?.widthTracksTextView = false
        twin.textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        twin.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        twin.typingAttributes = field.typingAttributes
        twin.defaultParagraphStyle = field.defaultParagraphStyle
        return twin
    }

    /// TextKit 2's caret segment at `index` (the `.standard` segment of an empty range).
    private func textKit2Caret(_ twin: NSTextView, at index: Int, upstream: Bool) -> CGRect? {
        guard let tlm = twin.textLayoutManager, let tcm = tlm.textContentManager,
              let loc = tcm.location(tcm.documentRange.location, offsetBy: index) else { return nil }
        tlm.ensureLayout(for: tlm.documentRange)
        var line: CGRect?
        tlm.enumerateTextSegments(in: NSTextRange(location: loc), type: .standard,
                                  options: upstream ? [.rangeNotRequired, .upstreamAffinity] : [.rangeNotRequired]) { _, rect, _, _ in
            line = rect
            return false
        }
        return line
    }

    static let caretTexts: [String] = [
        "hello world",
        "hi 👋🏽 there 👨‍👩‍👧 and done",
        "שלום עולם",
        "مرحبا بالعالم",
        "start שלום עולם end",
        "one line\nsecond line",
        "ends with a break\n",
        String(repeating: "a long paragraph that wraps across the composer field more than once ", count: 4),
        String(repeating: "שלום עולם זה טקסט ארוך ", count: 8),
    ] + mixedTexts

    /// Right-to-left text with left-to-right words and numbers in it, and the other way round.
    static let mixedTexts: [String] = [
        "שלום abc 123 עולם",
        "המחיר 42 שקלים ועוד 7",
        "עולם, hello 2026!",
        "price 42 שקלים and 7 more",
    ]

    /// Right-to-left (Hebrew, Arabic), left-to-right (a letter of another script) or nil (a space, a
    /// digit, punctuation, an emoji): the test's own strong-direction reading of one character.
    private static func strongDirection(_ c: unichar) -> Bool? {
        switch c {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return true
        default:
            guard let scalar = Unicode.Scalar(c), scalar.properties.isAlphabetic else { return nil }
            return false
        }
    }

    /// The direction of the visual run a character belongs to: a strong letter's, and left to right for
    /// a European digit (numbers lay out left to right inside right-to-left text).
    private static func runDirection(_ c: unichar) -> Bool? {
        (0x30...0x39).contains(c) ? false : strongDirection(c)
    }

    /// Where a left-to-right run meets a right-to-left one, the caret has two right places (either
    /// run's edge) and TextKit 1 and 2 may pick differently: such an index is left out.
    private static func atDirectionChange(_ units: NSString, _ index: Int) -> Bool {
        var before: Bool?, after: Bool?
        var i = index - 1
        while i >= 0, before == nil { before = runDirection(units.character(at: i)); i -= 1 }
        i = index
        while i < units.length, after == nil { after = runDirection(units.character(at: i)); i += 1 }
        return before != nil && after != nil && before != after
    }

    /// Whether the paragraph holding UTF-16 offset INDEX starts with a right-to-left letter (Unicode's
    /// rule P2: its first strong letter; none: left to right).
    private static func paragraphIsRightToLeft(_ units: NSString, at index: Int) -> Bool {
        let paragraph = units.paragraphRange(for: NSRange(location: min(index, units.length), length: 0))
        var i = paragraph.location
        while i < NSMaxRange(paragraph) {
            if let strong = strongDirection(units.character(at: i)) { return strong }
            i += 1
        }
        return false
    }

    /// The caret the field draws (its own caret view, from `textKit1CaretSegment`) is on TextKit 2's
    /// line and at TextKit 2's place in that line, at every character boundary: left-to-right,
    /// right-to-left, emoji sequences, a line break, the empty line after a final break, and both
    /// sides of a soft wrap. Each line starts at its paragraph's edge: the left for left-to-right
    /// text, the right for a paragraph whose first strong letter is right to left, every line of it
    /// (TextKit 2 started a one-line right-to-left paragraph at the right edge but the lines of a
    /// wrapped one at the left, its last line too).
    @Test(arguments: caretTexts) func theCaretSitsWhereTextKit2PutIt(_ text: String) async throws {
        let r = try await rig()
        defer { r.close() }
        let field = r.field
        r.window.makeFirstResponder(field)
        field.insertText(text, replacementRange: field.selectedRange())
        r.frame()
        let width = try #require(field.textContainer?.size.width)
        let twin = textKit2Twin(of: field, width: width)
        twin.textStorage?.setAttributedString(try #require(field.textStorage))
        let units = text as NSString
        struct Caret { var index: Int; var upstream: Bool; var mine: CGRect; var theirs: CGRect }
        var carets: [Caret] = []
        var mismatches: [String] = []
        var index = 0
        while index <= units.length {
            for upstream in [false, true] where !Self.atDirectionChange(units, index) {
                guard let mine = field.textKit1CaretSegment(at: index, upstream: upstream),
                      let theirs = textKit2Caret(twin, at: index, upstream: upstream) else {
                    mismatches.append("\(index) up \(upstream): no caret")
                    continue
                }
                carets.append(Caret(index: index, upstream: upstream, mine: mine, theirs: theirs))
            }
            index = index == units.length ? index + 1 : NSMaxRange(units.rangeOfComposedCharacterSequence(at: index))
        }
        // Each line's start: its first downstream caret (keyed by the line's y).
        var starts: [Int: Caret] = [:]
        for c in carets where !c.upstream && starts[Int(c.mine.minY.rounded())] == nil { starts[Int(c.mine.minY.rounded())] = c }
        for c in carets {
            let tag = "\(c.index) up \(c.upstream): TextKit 1 (\(c.mine.minX), \(c.mine.minY)) TextKit 2 (\(c.theirs.minX), \(c.theirs.minY))"
            guard abs(c.mine.minY - c.theirs.minY) <= 1, let start = starts[Int(c.mine.minY.rounded())] else {
                mismatches.append(tag + " line"); continue
            }
            if abs((c.mine.minX - start.mine.minX) - (c.theirs.minX - start.theirs.minX)) > 1 { mismatches.append(tag + " in line") }
        }
        for start in starts.values {
            let edge: CGFloat = Self.paragraphIsRightToLeft(units, at: start.index) ? width : 0
            if abs(start.mine.minX - edge) > 1 { mismatches.append("line at \(start.index) starts at \(start.mine.minX), not \(edge)") }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) carets off in \(text.prefix(30))…: \(mismatches.prefix(6).joined(separator: "; "))")
    }

    // MARK: Arrow keys and selection in mixed-direction text

    /// The field and its TextKit 2 twin with TEXT, the caret at the start of each.
    private func mixedPair(_ r: Rig, _ text: String) throws -> (FieldTextView, NSTextView) {
        let field = r.field
        r.window.makeFirstResponder(field)
        field.insertText(text, replacementRange: field.selectedRange())
        r.frame()
        let width = try #require(field.textContainer?.size.width)
        let twin = textKit2Twin(of: field, width: width)
        twin.textStorage?.setAttributedString(try #require(field.textStorage))
        field.setSelectedRange(NSRange(location: 0, length: 0))
        twin.setSelectedRange(NSRange(location: 0, length: 0))
        return (field, twin)
    }

    /// The caret the field draws for its selection (`textKit1CaretSegment`, by the selection's affinity).
    private func drawnCaret(_ field: NSTextView) -> CGRect? {
        field.textKit1CaretSegment(at: field.selectedRange().location, upstream: field.selectionAffinity == .upstream)
    }

    /// The right and left arrow keys walk the caret through Hebrew with English words and numbers in it
    /// (and English with Hebrew in it) as they did in TextKit 2: the same character offset after each
    /// key, the caret drawn moving the key's way on screen, never back, and each walk stopping at
    /// every character boundary of the line.
    @Test(arguments: mixedTexts) func theArrowKeysWalkMixedTextAsTextKit2Did(_ text: String) async throws {
        let r = try await rig()
        defer { r.close() }
        let (field, twin) = try mixedPair(r, text)
        let length = (text as NSString).length
        var problems: [String] = []
        var visited: [String: Set<Int>] = [:]
        // From the start of the line (its right edge in a right-to-left paragraph): first the reading
        // direction to the line's end, then back.
        let walks: [(String, (NSTextView) -> Void)] = [("right", { $0.moveRight(nil) }), ("left", { $0.moveLeft(nil) })]
        for (name, step) in Self.paragraphIsRightToLeft(text as NSString, at: 0) ? walks.reversed() : walks {
            var lastX = try #require(drawnCaret(field)).minX
            visited[name, default: []].insert(field.selectedRange().location)
            for key in 0..<(length + 2) {
                let before = field.selectedRange()
                step(field)
                step(twin)
                let mine = field.selectedRange(), theirs = twin.selectedRange()
                if mine != theirs { problems.append("\(name) \(key): offset \(mine.location) vs TextKit 2 \(theirs.location)") }
                if mine == before { break }
                visited[name, default: []].insert(mine.location)
                let x = try #require(drawnCaret(field)).minX
                if name == "right" ? x < lastX - 0.5 : x > lastX + 0.5 {
                    problems.append("\(name) \(key): the caret drawn at \(x) went back from \(lastX) (offset \(mine.location))")
                }
                lastX = x
            }
        }
        // Each walk stops at every character boundary of the line (no key skipped or stuck).
        let boundaries = Set((0...length).filter { $0 == length || (text as NSString).rangeOfComposedCharacterSequence(at: $0).location == $0 })
        #expect(visited["right"] == boundaries && visited["left"] == boundaries, "the arrows visited \(visited.mapValues { $0.count }) of \(boundaries.count) boundaries")
        #expect(problems.isEmpty, "\(problems.count) in \(text): \(problems.prefix(6).joined(separator: "; "))")
    }

    /// Shift with the arrow keys selects across a change of direction as TextKit 2 did (the same
    /// selected ranges after each key; where TextKit 2 could not reach the line's last character,
    /// TextKit 1 selecting it is right), the whole line in the end, and VoiceOver reads the selected text.
    @Test(arguments: mixedTexts) func shiftArrowsSelectAcrossADirectionChangeAsTextKit2Did(_ text: String) async throws {
        let r = try await rig()
        defer { r.close() }
        let (field, twin) = try mixedPair(r, text)
        let units = text as NSString
        var problems: [String] = []
        var selectedAll = false
        var theirsBefore = twin.selectedRanges.map(\.rangeValue)
        // Shift with the arrow of the paragraph's reading direction (Left in Hebrew), from its start.
        let rightToLeft = Self.paragraphIsRightToLeft(units, at: 0)
        for key in 0..<(units.length + 2) {
            let before = field.selectedRanges.map(\.rangeValue)
            if rightToLeft {
                field.moveLeftAndModifySelection(nil)
                twin.moveLeftAndModifySelection(nil)
            } else {
                field.moveRightAndModifySelection(nil)
                twin.moveRightAndModifySelection(nil)
            }
            let mine = field.selectedRanges.map(\.rangeValue), theirs = twin.selectedRanges.map(\.rangeValue)
            // TextKit 2 could not take the last character at the line's visual end (a number ending a
            // Hebrew line: its key did nothing); TextKit 1 selects the whole line there.
            let textKit2Stuck = theirs == theirsBefore && mine == [NSRange(location: 0, length: units.length)]
            if mine != theirs, !textKit2Stuck { problems.append("key \(key): \(mine) vs TextKit 2 \(theirs)") }
            theirsBefore = theirs
            if mine == before { break }
            selectedAll = mine.reduce(0) { $0 + $1.length } == units.length
            let selected = mine.map { units.substring(with: $0) }.joined()
            if let read = field.accessibilitySelectedText(), read != selected, mine.count == 1 {
                problems.append("key \(key): VoiceOver reads \"\(read)\", selected \"\(selected)\"")
            }
        }
        #expect(selectedAll, "Shift with the reading direction's arrow never selected the whole line")
        #expect(problems.isEmpty, "\(problems.count) in \(text): \(problems.prefix(6).joined(separator: "; "))")
    }

    // MARK: Input methods

    /// Japanese input at the end of a long draft: the marked text shows in the field while the store's
    /// draft is not replaced under it, and the commit leaves exactly the committed text, once, with the
    /// caret after it.
    @Test func markedTextAtTheEndOfALongDraftCommitsOnce() async throws {
        let r = try await rig()
        defer { r.close() }
        let field = r.field
        r.window.makeFirstResponder(field)
        let long = String(repeating: "the chief reads your note and starts on the work ", count: 90)
        field.insertText(long, replacementRange: field.selectedRange())
        r.frame()
        let length = (long as NSString).length
        field.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        r.frame()
        #expect(field.hasMarkedText())
        #expect(field.markedRange() == NSRange(location: length, length: 2))
        field.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        r.frame()
        #expect(field.markedRange() == NSRange(location: length, length: 4))
        field.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
        r.frame()
        #expect(!field.hasMarkedText())
        #expect(field.string == long + "日本語")
        #expect(draft(r) == long + "日本語", "the store's draft is the committed text")
        #expect(field.selectedRange() == NSRange(location: length + 3, length: 0))
        #expect(field.textKit1CaretSegment(at: length + 3, upstream: false) != nil)
    }

    // MARK: Undo

    /// Typing undoes as one group and redoes back, and the store's draft follows each.
    @Test func typingUndoesAndRedoesAsOneGroup() async throws {
        let r = try await rig()
        defer { r.close() }
        let field = r.field
        r.window.makeFirstResponder(field)
        let undo = try #require(field.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        field.insertText("first words", replacementRange: field.selectedRange())
        undo.endUndoGrouping()
        field.breakUndoCoalescing()
        undo.beginUndoGrouping()
        for c in " and more" { field.insertText(String(c), replacementRange: field.selectedRange()) }
        undo.endUndoGrouping()
        r.frame()
        #expect(field.string == "first words and more")
        undo.undo()
        r.frame()
        #expect(field.string == "first words")
        #expect(draft(r) == "first words")
        undo.redo()
        r.frame()
        #expect(field.string == "first words and more")
        #expect(draft(r) == "first words and more")
    }

    // MARK: VoiceOver

    /// VoiceOver reads the field through its accessibility text: the value, the character count, the
    /// caret's line and a character's frame on screen.
    @Test func voiceOverReadsTheTextAndItsLines() async throws {
        let r = try await rig()
        defer { r.close() }
        let field = r.field
        r.window.makeFirstResponder(field)
        let text = "first line\nsecond line שלום"
        field.insertText(text, replacementRange: field.selectedRange())
        r.frame()
        #expect(field.accessibilityValue() as? String == text)
        #expect(field.accessibilityNumberOfCharacters() == (text as NSString).length)
        #expect(field.accessibilityInsertionPointLineNumber() == 1)
        #expect(field.accessibilityLine(for: 3) == 0)
        #expect(field.accessibilityRange(forLine: 1).location == 11)
        let frame = field.accessibilityFrame(for: NSRange(location: 12, length: 1))
        #expect(frame.width > 0 && frame.height > 0, "a character's frame for VoiceOver's cursor: \(frame)")
        #expect(field.accessibilityString(for: NSRange(location: 0, length: 5)) == "first")
    }

    // MARK: Writing Tools and spelling

    /// Writing Tools keeps the composer's setting (`.limited` by default: the panel, no inline rewrite),
    /// and a misspelled word gets its spelling mark from the deferred checker (TextKit 1 keeps it as a
    /// temporary attribute).
    @Test func writingToolsAndSpellingMarksKeepTheirSettings() async throws {
        let r = try await rig()
        defer { r.close() }
        let field = r.field
        r.window.makeFirstResponder(field)
        if #available(macOS 15, *) { #expect(field.writingToolsBehavior == ComposeView.writingTools) }
        #expect(!field.isGrammarCheckingEnabled)
        r.view.composerSpellCheckingEnabled = true  // the host's opt-in (Settings)
        field.insertText("this is a mispeled wrod here ", replacementRange: field.selectedRange())
        r.frame()
        let lm = try #require(field.layoutManager)
        let word = (field.string as NSString).range(of: "mispeled")
        let deadline = ContinuousClock.now + .seconds(10)
        var marked = false
        while !marked, ContinuousClock.now < deadline {
            // A bounded wait: the check runs in the spell server (another process) and its reply reaches
            // the main actor with no signal a test can await.
            try await Task.sleep(for: .milliseconds(20))
            let state = lm.temporaryAttribute(.spellingState, atCharacterIndex: word.location, effectiveRange: nil) as? Int
            marked = (state ?? 0) != 0
        }
        #expect(marked, "no spelling mark on a misspelled word")
    }
}
