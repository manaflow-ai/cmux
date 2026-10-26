#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its text input.
import AppKit
@testable import CmuxNextBrowser
import Testing

/// The page's NSTextInputClient in host mode (p01-process-043): one key's input method calls
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

    /// Korean: Return ends the composition (unmarkText) and still makes a new line, after it.
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
            Self.marked(backspace, .inputMethod, ch: 0), .op(.finishComposing),
            .op(.keyCommands(["DeleteBackward"])), Self.marked(backspace, .plain, ch: 0),
        ])
    }

    /// An input method that ends the composition and binds Return to insertNewline: sends the
    /// newline as a character after the composition ends.
    @Test func anInsertCommandAfterAnUnmarkSendsTheCharacterOnly() {
        var input = editing()
        input.beginKey()
        _ = input.setMarkedText("x", clauses: [], selection: 1..<1, replacement: nil)
        _ = input.endKey(Self.key(7, ch: 0x78), controlOrCommand: false)
        let enter = Self.key(36, ch: 0x0d)
        input.beginKey()
        _ = input.unmarkText()
        _ = input.doCommand("insertNewline:")
        #expect(input.endKey(enter, controlOrCommand: false) == [
            Self.marked(enter, .inputMethod, ch: 0), .op(.finishComposing), Self.marked(enter, .characterOnly, ch: 0x0d),
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
        #expect(input.stats.syncRequests == 0)
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
                                        makeLayerHost: { _ in CALayer() }, pageUpdateCenter: NotificationCenter())
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
        #expect(page.textInput.stats.syncRequests == 0)

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
        page.sink = { frames.append($0) }
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
}
#endif
