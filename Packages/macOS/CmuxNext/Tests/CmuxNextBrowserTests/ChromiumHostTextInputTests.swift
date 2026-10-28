#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its text input.
import AppKit
@testable import CmuxNextBrowser
import Testing

/// The page's NSTextInputClient in host mode: one key's input method calls
/// become Chrome's key frames and ops in Chrome's order, and every question is answered from the
/// state the host pushed, never by asking it.
@MainActor
@Suite struct ChromiumHostTextInputTests {
    typealias Output = ChromiumHostTextInput.Output

    /// A key down as the page view writes it before the input method's turn.
    static func key(_ code: Int32, ch: UInt16, unmod: UInt16? = nil) -> ChromiumHostFrame {
        var frame = ChromiumHostFrame(.key, v: [0, code, 0])
        frame.ch = ch
        frame.unmod = unmod ?? ch
        return frame
    }

    static func marked(_ key: ChromiumHostFrame, _ mark: ChromiumHostTextInput.KeyMark, ch: UInt16) -> Output {
        var frame = key
        frame.v[3] = mark.rawValue
        frame.ch = ch
        return .key(frame)
    }

    /// The up that balances a process key down before the real key follows it.
    static func processKeyUp(_ key: ChromiumHostFrame) -> Output {
        var frame = key
        frame.v[0] = 1
        frame.v[3] = ChromiumHostTextInput.KeyMark.inputMethod.rawValue
        frame.ch = 0
        return .key(frame)
    }

    static let field = ChromiumHostTextInputState(type: .text, selection: 3..<3, text: "abc", textOffset: 0,
                                                  caretRect: CGRect(x: 30, y: 10, width: 1, height: 16))

    func editing() -> ChromiumHostTextInput {
        var input = ChromiumHostTextInput()
        _ = input.apply(Self.field)
        return input
    }

    // MARK: Key turns

    @Test func aTypedCharacterIsOneKeyFrameWithIt() {
        var input = editing()
        let a = Self.key(0, ch: 0x61)
        input.beginKey()
        #expect(input.insertText("a", replacement: nil).isEmpty)
        #expect(input.endKey(a, controlOrCommand: false) == [Self.marked(a, .plain, ch: 0x61)])
    }

    @Test func aKeyBoundToAnEditCommandSendsTheCommandAndNoCharacter() {
        var input = editing()
        let backspace = Self.key(51, ch: 0x7f)
        input.beginKey()
        #expect(input.doCommand("deleteBackward:").isEmpty)
        #expect(input.endKey(backspace, controlOrCommand: false)
            == [.op(.keyCommands(["DeleteBackward"])), Self.marked(backspace, .plain, ch: 0)])
    }

    /// Return and Tab: an insert command is not sent; the key's own character carries it.
    @Test func anInsertCommandKeepsTheKeysCharacter() {
        var input = editing()
        let enter = Self.key(36, ch: 0x0d)
        input.beginKey()
        _ = input.doCommand("insertNewline:")
        #expect(input.endKey(enter, controlOrCommand: false) == [Self.marked(enter, .plain, ch: 0x0d)])
    }

    @Test func controlOrCommandKeepsTheKeysCharacter() {
        var input = editing()
        let controlA = Self.key(0, ch: 0x01, unmod: 0x61)
        input.beginKey()
        #expect(input.endKey(controlA, controlOrCommand: true) == [Self.marked(controlA, .plain, ch: 0x01)])
    }

    /// Kotoeri: k, a (marked "か"), Return commits.
    @Test func aCompositionGoesAsProcessKeysAndOpsThenCommits() {
        var input = editing()
        let k = Self.key(40, ch: 0x6b)
        input.beginKey()
        _ = input.setMarkedText("k", clauses: [.init(range: 0..<1, thick: false)], selection: 1..<1, replacement: nil)
        #expect(input.endKey(k, controlOrCommand: false) == [
            Self.marked(k, .inputMethod, ch: 0),
            .op(.setComposition(text: "k", clauses: [.init(range: 0..<1, thick: false)], selection: 1..<1, replacement: nil)),
        ])
        #expect(input.hasMarkedText)
        #expect(input.markedRange == 3..<4)

        let a = Self.key(0, ch: 0x61)
        input.beginKey()
        _ = input.setMarkedText("か", clauses: [.init(range: 0..<1, thick: true)], selection: 1..<1, replacement: nil)
        #expect(input.endKey(a, controlOrCommand: false) == [
            Self.marked(a, .inputMethod, ch: 0),
            .op(.setComposition(text: "か", clauses: [.init(range: 0..<1, thick: true)], selection: 1..<1, replacement: nil)),
        ])

        let enter = Self.key(36, ch: 0x0d)
        input.beginKey()
        _ = input.insertText("か", replacement: nil)
        #expect(input.endKey(enter, controlOrCommand: false) == [
            Self.marked(enter, .inputMethod, ch: 0), .op(.commitText("か", replacement: nil)),
        ])
        #expect(!input.hasMarkedText)
        #expect(input.markedRange == nil)
    }

    /// A dead key: Option-e marks "´", then e inserts "é".
    @Test func aDeadKeyCommitsTheComposedCharacter() {
        var input = editing()
        let optionE = Self.key(14, ch: 0xb4, unmod: 0x65)
        input.beginKey()
        _ = input.setMarkedText("´", clauses: [], selection: 1..<1, replacement: nil)
        _ = input.endKey(optionE, controlOrCommand: false)
        let e = Self.key(14, ch: 0xe9, unmod: 0x65)
        input.beginKey()
        _ = input.insertText("é", replacement: nil)
        #expect(input.endKey(e, controlOrCommand: false) == [
            Self.marked(e, .inputMethod, ch: 0), .op(.commitText("é", replacement: nil)),
        ])
    }

    /// Korean: Backspace ends the composition (unmarkText) and still deletes, after it. The
    /// process key down gets its up before the real key down, so the page's keys balance.
    @Test func aKeyThatEndsTheCompositionWithCommandsFollowsIt() {
        var input = editing()
        input.beginKey()
        _ = input.setMarkedText("한", clauses: [], selection: 1..<1, replacement: nil)
        _ = input.endKey(Self.key(4, ch: 0x67), controlOrCommand: false)
        let backspace = Self.key(51, ch: 0x7f)
        input.beginKey()
        _ = input.unmarkText()
        _ = input.doCommand("deleteBackward:")
        #expect(input.endKey(backspace, controlOrCommand: false) == [
            Self.marked(backspace, .inputMethod, ch: 0), .op(.finishComposing), Self.processKeyUp(backspace),
            .op(.keyCommands(["DeleteBackward"])), Self.marked(backspace, .plain, ch: 0),
        ])
    }

    /// Korean 2-Set: Return commits the syllable (insertText) and binds insertNewline:. The real
    /// Return follows the commit with its own character, so pages see keydown 13 and a new line.
    @Test func returnThatCommitsAndInsertsANewlineSendsTheRealKey() {
        var input = editing()
        input.beginKey()
        _ = input.setMarkedText("한", clauses: [], selection: 1..<1, replacement: nil)
        _ = input.endKey(Self.key(4, ch: 0x67), controlOrCommand: false)
        let enter = Self.key(36, ch: 0x0d)
        input.beginKey()
        _ = input.insertText("한", replacement: nil)
        _ = input.doCommand("insertNewline:")
        #expect(input.endKey(enter, controlOrCommand: false) == [
            Self.marked(enter, .inputMethod, ch: 0), .op(.commitText("한", replacement: nil)), Self.processKeyUp(enter),
            Self.marked(enter, .plain, ch: 0x0d),
        ])
    }

    /// An input method that ends the composition and binds Return to insertNewline: sends the
    /// real Return key down, with its character, after the composition ends.
    @Test func anInsertCommandAfterAnUnmarkSendsTheRealKey() {
        var input = editing()
        input.beginKey()
        _ = input.setMarkedText("x", clauses: [], selection: 1..<1, replacement: nil)
        _ = input.endKey(Self.key(7, ch: 0x78), controlOrCommand: false)
        let enter = Self.key(36, ch: 0x0d)
        input.beginKey()
        _ = input.unmarkText()
        _ = input.doCommand("insertNewline:")
        #expect(input.endKey(enter, controlOrCommand: false) == [
            Self.marked(enter, .inputMethod, ch: 0), .op(.finishComposing), Self.processKeyUp(enter),
            Self.marked(enter, .plain, ch: 0x0d),
        ])
    }

    /// A key that sets new marked text and also chose a command: the composition holds the
    /// key, so neither the real key nor its command goes (Chrome's `!_hasMarkedText`).
    @Test func aKeyThatKeepsMarkedTextSendsNoDelayedKey() {
        var input = editing()
        input.beginKey()
        _ = input.setMarkedText("か", clauses: [], selection: 1..<1, replacement: nil)
        _ = input.endKey(Self.key(0, ch: 0x61), controlOrCommand: false)
        let left = Self.key(123, ch: 0xf702)
        input.beginKey()
        _ = input.setMarkedText("かな", clauses: [], selection: 1..<1, replacement: nil)
        _ = input.doCommand("moveLeft:")
        #expect(input.endKey(left, controlOrCommand: false) == [
            Self.marked(left, .inputMethod, ch: 0),
            .op(.setComposition(text: "かな", clauses: [], selection: 1..<1, replacement: nil)),
        ])
    }

    @Test func emptyMarkedTextInAKeyCancelsTheComposition() {
        var input = editing()
        input.beginKey()
        _ = input.setMarkedText("x", clauses: [], selection: 1..<1, replacement: nil)
        _ = input.endKey(Self.key(7, ch: 0x78), controlOrCommand: false)
        let escape = Self.key(53, ch: 0x1b)
        input.beginKey()
        _ = input.setMarkedText("", clauses: [], selection: 0..<0, replacement: nil)
        #expect(input.endKey(escape, controlOrCommand: false)
            == [Self.marked(escape, .inputMethod, ch: 0), .op(.cancelComposition)])
    }

    // MARK: Calls outside a key

    @Test func callsOutsideAKeyGoAtOnce() {
        var input = editing()
        #expect(input.setMarkedText("に", clauses: [], selection: 1..<1, replacement: 2..<3)
            == [.op(.setComposition(text: "に", clauses: [], selection: 1..<1, replacement: 2..<3))])
        #expect(input.unmarkText() == [.op(.finishComposing)])
        #expect(input.unmarkText().isEmpty)
        #expect(input.insertText("🙂", replacement: nil) == [.op(.commitText("🙂", replacement: nil))])
        #expect(input.doCommand("moveWordLeft:") == [.op(.editCommand("MoveWordLeft"))])
        #expect(input.doCommand("noop:").isEmpty)
    }

    /// Dictation replaces a range even inside a key: it commits at once.
    @Test func aReplacementInsideAKeyCommitsAtOnce() {
        var input = editing()
        input.beginKey()
        #expect(input.insertText("x", replacement: 0..<1) == [.op(.commitText("x", replacement: 0..<1))])
        let key = Self.key(7, ch: 0x78)
        #expect(input.endKey(key, controlOrCommand: false) == [Self.marked(key, .plain, ch: 0)])
    }

    @Test func leavingEveryFieldDropsTheCompositionHereOnly() {
        var input = editing()
        _ = input.setMarkedText("x", clauses: [], selection: 1..<1, replacement: nil)
        #expect(input.apply(ChromiumHostTextInputState()) == .init(discardMarkedText: true))
        #expect(!input.hasMarkedText)
        #expect(input.finishComposition().isEmpty)
    }

    /// A script moves focus from a text field to a password field mid-composition: the
    /// composition ends here, and the next key is a plain key, not an input method commit.
    @Test func aMoveToAPasswordFieldDropsTheComposition() {
        var input = editing()
        _ = input.setMarkedText("か", clauses: [], selection: 1..<1, replacement: nil)
        var shown = Self.field
        shown.composition = 3..<4
        shown.compositionRects = [CGRect(x: 30, y: 10, width: 8, height: 16)]
        #expect(input.apply(shown) == .init(invalidateCharacterCoordinates: true))
        #expect(input.apply(ChromiumHostTextInputState(type: .password, selection: 0..<0)) == .init(discardMarkedText: true))
        #expect(!input.hasMarkedText)
        let a = Self.key(0, ch: 0x61)
        input.beginKey()
        _ = input.insertText("a", replacement: nil)
        #expect(input.endKey(a, controlOrCommand: false) == [Self.marked(a, .plain, ch: 0x61)])
    }

    /// A script moves focus to another text field: the page ended the composition on blur, so the
    /// new field's push has none, and the composition ends here instead of going into that field.
    @Test func aMoveToAnotherTextFieldDropsTheComposition() {
        var input = editing()
        _ = input.setMarkedText("か", clauses: [], selection: 1..<1, replacement: nil)
        var shown = Self.field
        shown.composition = 3..<4
        shown.compositionRects = [CGRect(x: 30, y: 10, width: 8, height: 16)]
        _ = input.apply(shown)
        let other = ChromiumHostTextInputState(type: .text, selection: 0..<0, text: "", textOffset: 0,
                                               caretRect: CGRect(x: 5, y: 80, width: 1, height: 16))
        #expect(input.apply(other) == .init(discardMarkedText: true))
        #expect(!input.hasMarkedText)

        var search = editing()
        _ = search.setMarkedText("か", clauses: [], selection: 1..<1, replacement: nil)
        var searchField = Self.field
        searchField.type = .search
        #expect(search.apply(searchField) == .init(discardMarkedText: true), "a field of another type")
    }

    /// A push the host sent before it applied cmux's composition op has no composition yet: the
    /// composition stays.
    @Test func aPushThatPredatesTheCompositionOpKeepsIt() {
        var input = editing()
        _ = input.setMarkedText("か", clauses: [], selection: 1..<1, replacement: nil)
        var moved = Self.field
        moved.caretRect.origin.x += 1
        #expect(input.apply(moved) == .init(invalidateCharacterCoordinates: true))
        #expect(input.hasMarkedText)
    }

    @Test func movedCompositionRectsAskTheInputMethodToReadThemAgain() {
        var input = editing()
        _ = input.setMarkedText("x", clauses: [], selection: 1..<1, replacement: nil)
        var moved = Self.field
        moved.composition = 3..<4
        moved.compositionRects = [CGRect(x: 30, y: 40, width: 8, height: 16)]
        #expect(input.apply(moved) == .init(invalidateCharacterCoordinates: true))
        #expect(input.finishComposition() == [.op(.finishComposing)])
    }

    // MARK: Questions from pushed state

    static let composing = ChromiumHostTextInputState(
        type: .text, selection: 7..<7, text: "hello world", textOffset: 2, composition: 4..<8,
        compositionRects: [CGRect(x: 0, y: 0, width: 10, height: 20), CGRect(x: 10, y: 0, width: 10, height: 20),
                           CGRect(x: 0, y: 22, width: 10, height: 20), CGRect(x: 10, y: 22, width: 10, height: 20)],
        caretRect: CGRect(x: 20, y: 22, width: 1, height: 20))

    @Test func theCaretRangeGetsTheCaretRect() {
        let found = Self.field.firstRect(for: 3..<3)
        #expect(found?.rect == Self.field.caretRect)
        #expect(found?.actual == 3..<3)
    }

    @Test func aCompositionRangeStopsAtItsFirstLineBreak() {
        let found = Self.composing.firstRect(for: 4..<8)
        #expect(found?.rect == CGRect(x: 0, y: 0, width: 20, height: 20))
        #expect(found?.actual == 4..<6)
        let second = Self.composing.firstRect(for: 6..<8)
        #expect(second?.rect == CGRect(x: 0, y: 22, width: 20, height: 20))
        #expect(second?.actual == 6..<8)
    }

    @Test func anEmptyRangeInTheCompositionIsAZeroWidthRect() {
        #expect(Self.composing.firstRect(for: 5..<5)?.rect == CGRect(x: 10, y: 0, width: 0, height: 20))
        #expect(Self.composing.firstRect(for: 8..<8)?.rect == CGRect(x: 20, y: 22, width: 0, height: 20))
    }

    @Test func aRangeOutsideThePushedStateIsAMissAnsweredWithTheCaret() {
        #expect(Self.composing.firstRect(for: 0..<2) == nil)
        var mismatched = Self.composing
        mismatched.compositionRects.removeLast()
        #expect(mismatched.firstRect(for: 4..<5) == nil)

        var input = ChromiumHostTextInput()
        _ = input.apply(Self.composing)
        #expect(input.firstRect(for: 0..<2).rect == Self.composing.caretRect)
        #expect(input.firstRect(for: 4..<5).rect == CGRect(x: 0, y: 0, width: 10, height: 20))
        #expect(input.stats.firstRectMisses == 1)
        #expect(input.stats.firstRectAnswers == 1)
        _ = input.characterIndex(at: CGPoint(x: 500, y: 500))
        #expect(input.stats.report == ["ime_first_rect_answers": 1, "ime_first_rect_misses": 1,
                                       "ime_character_index_misses": 1])
    }

    @Test func aSelectionWithoutACompositionGetsItsFirstRect() {
        var state = Self.field
        state.selection = 1..<3
        #expect(state.firstRect(for: 2..<3)?.actual == 1..<3)
        #expect(state.firstRect(for: 0..<3) == nil)
    }

    @Test func aPointFindsTheCompositionCharacterUnderIt() {
        #expect(Self.composing.characterIndex(at: CGPoint(x: 15, y: 30)) == 7)
        #expect(Self.composing.characterIndex(at: CGPoint(x: 50, y: 50)) == nil)
        #expect(Self.field.characterIndex(at: CGPoint(x: 1, y: 1)) == nil)
    }

    @Test func substringsComeFromThePushedTextOrTheMarkedText() {
        #expect(Self.field.substring(of: 1..<2, markedText: [])?.text == "b")
        #expect(Self.field.substring(of: 2..<9, markedText: [])?.actual == 2..<3)
        #expect(Self.field.substring(of: 5..<9, markedText: []) == nil)
        let marked = Self.composing.substring(of: 5..<7, markedText: Array("かなかな".utf16))
        #expect(marked?.text == "なか")
        #expect(marked?.actual == 5..<7)
    }

    @Test func selectorsBecomeBlinkEditCommands() {
        #expect(ChromiumHostTextInput.editCommand("deleteWordBackward:") == "DeleteWordBackward")
        #expect(ChromiumHostTextInput.editCommand("moveToEndOfDocumentAndModifySelection:")
            == "MoveToEndOfDocumentAndModifySelection")
    }

    // MARK: The view

    func makePage() -> (ChromiumHostPageView, NSWindow) {
        _ = NSApplication.shared
        let page = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), inputTarget: .view,
                                        makeLayerHost: { _ in CALayer() }, windowEventCenter: NotificationCenter())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(page)
        return (page, window)
    }

    @Test func theViewSendsInputMethodCallsAsOpsAndNeverWaits() {
        let (page, window) = makePage()
        defer { window.close() }
        var ops: [ChromiumHostTextInputOp] = []
        page.textInputSink = { ops.append($0) }
        page.applyTextInputState(Self.field)
        let underlined = NSAttributedString(string: "かな", attributes: [.underlineStyle: NSUnderlineStyle.thick.rawValue])
        page.setMarkedText(underlined, selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(page.hasMarkedText())
        #expect(page.markedRange() == NSRange(location: 3, length: 2))
        page.insertText("仮名", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(ops == [
            .setComposition(text: "かな", clauses: [.init(range: 0..<2, thick: true)], selection: 2..<2, replacement: nil),
            .commitText("仮名", replacement: nil),
        ])
        #expect(!page.hasMarkedText())
        #expect(page.selectedRange() == NSRange(location: 3, length: 0))
    }

    @Test func theViewAnswersGeometryInScreenPointsFromPushedRects() {
        let (page, window) = makePage()
        defer { window.close() }
        page.applyTextInputState(Self.field)
        var actual = NSRange(location: NSNotFound, length: 0)
        let rect = page.firstRect(forCharacterRange: NSRange(location: 3, length: 0), actualRange: &actual)
        #expect(actual == NSRange(location: 3, length: 0))
        // The caret at (30, 10) top-left, 16 tall, in a 300-tall page at screen (100, 100).
        #expect(rect == NSRect(x: 130, y: 100 + 300 - 26, width: 1, height: 16))
        #expect(page.textInput.stats.firstRectAnswers == 1)

        var substringRange = NSRange()
        #expect(page.attributedSubstring(forProposedRange: NSRange(location: 0, length: 2), actualRange: &substringRange)?
            .string == "ab")
        #expect(substringRange == NSRange(location: 0, length: 2))
        #expect(page.characterIndex(for: NSPoint(x: 0, y: 0)) == NSNotFound)
    }

    /// With no field focused there is no input context: AppKit's key bindings still insert the
    /// typed character, and it goes with the key.
    @Test func aKeyDownWithNoFieldStillTypesItsCharacter() throws {
        let (page, window) = makePage()
        defer { window.close() }
        var frames: [ChromiumHostFrame] = []
        page.sink = { frames.append($0); return nil }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                                  windowNumber: window.windowNumber, context: nil, characters: "a",
                                                  charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        page.keyDown(with: event)
        #expect(frames.map(\.ch) == [0x61])
        #expect(frames.map { $0.v[3] } == [ChromiumHostTextInput.KeyMark.plain.rawValue])
    }

    @Test func noFieldAndPasswordFieldsHaveNoInputMethod() {
        let (page, window) = makePage()
        defer { window.close() }
        #expect(page.inputContext == nil)
        page.applyTextInputState(ChromiumHostTextInputState(type: .password, selection: 0..<0))
        #expect(page.inputContext == nil)
        page.applyTextInputState(Self.field)
        #expect(page.inputContext != nil)
    }

    /// What a page view sent, in order: mouse frames by phase and text input ops.
    enum Sent: Equatable {
        case mouse(phase: Int32)
        case op(ChromiumHostTextInputOp)
    }

    /// A click while composing: the composition ends with its text kept, then the page gets the
    /// down and its up, so its button state balances.
    @Test func aMouseDownWhileComposingFinishesTheCompositionThenClicks() throws {
        let (page, window) = makePage()
        defer { window.close() }
        var sent: [Sent] = []
        page.sink = { frame in
            if frame.kind == .mouse { sent.append(.mouse(phase: frame.v[2])) }
            return nil
        }
        page.textInputSink = { sent.append(.op($0)) }
        page.applyTextInputState(Self.field)
        page.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        sent.removeAll()
        func click(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 1,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                            clickCount: 1, pressure: 1))
        }
        page.mouseDown(with: try click(.leftMouseDown))
        page.mouseUp(with: try click(.leftMouseUp))
        #expect(sent == [.op(.finishComposing), .mouse(phase: 1), .mouse(phase: 2)])
        #expect(!page.hasMarkedText())
    }

    @Test func resigningDropsTheCompositionWithoutAnOp() {
        let (page, window) = makePage()
        defer { window.close() }
        var ops: [ChromiumHostTextInputOp] = []
        page.textInputSink = { ops.append($0) }
        page.applyTextInputState(Self.field)
        page.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = page.resignFirstResponder()
        #expect(!page.hasMarkedText())
        #expect(ops.count == 1)
    }

    // MARK: The wire

    @Test func aCompositionOpIsAnImeFrameWithItsTextAndClauses() {
        let frame = ChromiumHostFrame(textInput: .setComposition(
            text: "かな", clauses: [.init(range: 0..<1, thick: true, color: 0xFF11_2233)], selection: 2..<2,
            replacement: 4..<5))
        #expect(frame.kind == .ime)
        #expect(frame.v == [0, 2, 2, 4, 5, 1])
        #expect(frame.payload == [0x4B, 0x30, 0x6A, 0x30,  // か な, UTF-16LE
                                  0, 0, 0, 0, 1, 0, 0, 0, 0x33, 0x22, 0x11, 0xFF, 1, 0, 0, 0])
        let commit = ChromiumHostFrame(textInput: .commitText("a", replacement: nil))
        #expect(commit.v == [1, 0, 0, -1, -1, 0])
        #expect(commit.payload == [0x61, 0])
        #expect(ChromiumHostFrame(textInput: .finishComposing).v[0] == 2)
        #expect(ChromiumHostFrame(textInput: .cancelComposition).v[0] == 3)
        let commands = ChromiumHostFrame(textInput: .keyCommands(["MoveLeft", "DeleteBackward"]))
        #expect(commands.v[0] == 4)
        let units = stride(from: 0, to: commands.payload.count, by: 2).map {
            UInt16(commands.payload[$0]) | UInt16(commands.payload[$0 + 1]) << 8
        }
        #expect(String(decoding: units, as: UTF16.self) == "MoveLeft\nDeleteBackward")
        #expect(ChromiumHostFrame(textInput: .editCommand("SelectAll")).v[0] == 5)
    }

    static func stateFrame(caret: [Int32], textOffset: Int32, rects: [[Int32]], text: String) -> ChromiumHostFrame {
        var payload: [UInt8] = []
        func put(_ value: Int32) { withUnsafeBytes(of: value.littleEndian) { payload.append(contentsOf: $0) } }
        caret.forEach(put)
        put(textOffset)
        put(Int32(rects.count))
        rects.joined().forEach(put)
        for unit in text.utf16 { withUnsafeBytes(of: unit.littleEndian) { payload.append(contentsOf: $0) } }
        return ChromiumHostFrame(.textInputState, v: [1, 8, 7, 7, 4, 6], payload: payload)
    }

    @Test func aTextInputStateFrameDecodesToThePushedState() throws {
        let frame = Self.stateFrame(caret: [20, 22, 1, 20], textOffset: 2,
                                    rects: [[0, 0, 10, 20], [10, 0, 10, 20]], text: "hello world")
        let state = try #require(ChromiumHostTextInputState(frame: frame))
        #expect(state == ChromiumHostTextInputState(
            type: .text, flags: 8, selection: 7..<7, text: "hello world", textOffset: 2, composition: 4..<6,
            compositionRects: [CGRect(x: 0, y: 0, width: 10, height: 20), CGRect(x: 10, y: 0, width: 10, height: 20)],
            caretRect: CGRect(x: 20, y: 22, width: 1, height: 20)))

        var unknown = frame
        unknown.v[2...5] = [-1, -1, -1, -1]
        let none = try #require(ChromiumHostTextInputState(frame: unknown))
        #expect(none.selection == nil)
        #expect(none.composition == nil)
    }

    @Test func aMalformedTextInputStateFrameIsRefused() {
        let good = Self.stateFrame(caret: [0, 0, 0, 0], textOffset: 0, rects: [[0, 0, 1, 1]], text: "ab")
        var short = good
        short.payload = Array(good.payload.prefix(20))
        var tooManyRects = good
        tooManyRects.payload[20] = 9
        var oddText = good
        oddText.payload.append(0)
        var otherKind = good
        otherKind.rawKind = ChromiumHostFrame.Kind.title.rawValue
        #expect(ChromiumHostTextInputState(frame: good) != nil)
        #expect(ChromiumHostTextInputState(frame: short) == nil)
        #expect(ChromiumHostTextInputState(frame: tooManyRects) == nil)
        #expect(ChromiumHostTextInputState(frame: oddText) == nil)
        #expect(ChromiumHostTextInputState(frame: otherKind) == nil)
    }
}
#endif
