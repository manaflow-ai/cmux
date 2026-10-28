#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its text input.
import AppKit
@testable import CmuxNextBrowser
import Testing

/// Host IME: a Japanese conversion's order, whole characters on every frame,
/// bounded ops the host always takes, and firstRect from the last push.
extension ChromiumHostTextInputTests {
    /// Kotoeri conversion: "にほん" marked, Space converts to "日本" with its clause selected,
    /// Return commits. Every composition goes before the commit, each after its process key.
    @Test func aJapaneseConversionSendsEachCompositionThenTheCommit() {
        var input = editing()
        var sent: [Output] = []
        let typed: [(code: Int32, ch: UInt16, marked: String)] = [
            (45, 0x6e, "n"), (34, 0x69, "に"), (4, 0x68, "にh"), (31, 0x6f, "にほ"), (45, 0x6e, "にほn"),
            (45, 0x6e, "にほん"),
        ]
        for key in typed {
            let length = key.marked.utf16.count
            input.beginKey()
            _ = input.setMarkedText(key.marked, clauses: [.init(range: 0..<length, thick: false)],
                                    selection: length..<length, replacement: nil)
            sent += input.endKey(Self.key(key.code, ch: key.ch), controlOrCommand: false)
        }
        input.beginKey()
        _ = input.setMarkedText("日本", clauses: [.init(range: 0..<2, thick: true)], selection: 2..<2, replacement: nil)
        sent += input.endKey(Self.key(49, ch: 0x20), controlOrCommand: false)
        input.beginKey()
        _ = input.insertText("日本", replacement: nil)
        sent += input.endKey(Self.key(36, ch: 0x0d), controlOrCommand: false)

        let ops = sent.compactMap { output -> String? in
            guard case .op(let op) = output else { return nil }
            switch op {
            case .setComposition(let text, _, _, _): return "set \(text)"
            case .commitText(let text, _): return "commit \(text)"
            default: return "other"
            }
        }
        #expect(ops == ["set n", "set に", "set にh", "set にほ", "set にほn", "set にほん", "set 日本", "commit 日本"])
        // Every key of the conversion is a process key with no character: pages see keyCode 229.
        #expect(sent.allSatisfy { output in
            guard case .key(let frame) = output else { return true }
            return frame.v[3] == ChromiumHostTextInput.KeyMark.inputMethod.rawValue && frame.ch == 0
        })
        #expect(!input.hasMarkedText)
    }

    /// A character outside the BMP is two UTF-16 units: it commits whole after a process key, and
    /// no key frame carries half of it.
    @Test func aCharacterOfTwoUnitsCommitsWhole() {
        var input = editing()
        let key = Self.key(0, ch: ChromiumHostTextInput.keyCharacter("😀"))
        #expect(key.ch == 0)
        input.beginKey()
        _ = input.insertText("😀", replacement: nil)
        #expect(input.endKey(key, controlOrCommand: false) == [
            Self.marked(key, .inputMethod, ch: 0), .op(.commitText("😀", replacement: nil)),
        ])
    }

    @Test func aKeyFrameCarriesOnlyAWholeCharacter() {
        #expect(ChromiumHostTextInput.keyCharacter("a") == 0x61)
        #expect(ChromiumHostTextInput.keyCharacter("é") == 0xe9)
        #expect(ChromiumHostTextInput.keyCharacter("😀") == 0)
        #expect(ChromiumHostTextInput.keyCharacter("ab") == 0)
        #expect(ChromiumHostTextInput.keyCharacter("") == 0)
        #expect(ChromiumHostTextInput.keyCharacter(nil) == 0)
    }

    /// Marked text over 4 KiB keeps its first units without splitting a pair, and its clauses
    /// and selection inside them, here and in the op alike.
    @Test func aLongCompositionKeepsItsFirstUnitsWhole() {
        var input = editing()
        let kept = ChromiumHostTextInput.maxCompositionUnits - 1
        let text = String(repeating: "a", count: kept) + "😀b"
        let outputs = input.setMarkedText(text, clauses: [.init(range: 0..<10, thick: true),
                                                          .init(range: kept..<(kept + 3), thick: false),
                                                          .init(range: (kept + 2)..<(kept + 3), thick: false)],
                                          selection: (kept + 3)..<(kept + 3), replacement: nil)
        #expect(input.markedText.count == kept)
        #expect(input.markedRange == 3..<(3 + kept))
        #expect(outputs == [.op(.setComposition(text: String(repeating: "a", count: kept),
                                                clauses: [.init(range: 0..<10, thick: true)],
                                                selection: kept..<kept, replacement: nil))])
        for case .op(let op) in outputs {
            #expect(ChromiumHostConnection.fits(ChromiumHostFrame(textInput: op)))
        }
    }

    /// Dictation of more text than one frame holds: consecutive commits, each a frame the host
    /// takes, the replacement on the first only.
    @Test func aLongInsertCommitsInFramesTheHostTakes() {
        var input = editing()
        let first = ChromiumHostTextInput.maxCommitUnits - 1
        let rest = "😀" + String(repeating: "y", count: 10)
        let outputs = input.insertText(String(repeating: "x", count: first) + rest, replacement: 0..<1)
        #expect(outputs == [
            .op(.commitText(String(repeating: "x", count: first), replacement: 0..<1)),
            .op(.commitText(rest, replacement: nil)),
        ])
        for case .op(let op) in outputs {
            #expect(ChromiumHostConnection.fits(ChromiumHostFrame(textInput: op)))
        }
    }

    // MARK: The view

    /// A key whose character is two UTF-16 units: no frame carries half of it.
    @Test func aKeyDownOfATwoUnitCharacterSendsNoHalfOfIt() throws {
        let (page, window) = makePage()
        defer { window.close() }
        var frames: [ChromiumHostFrame] = []
        page.sink = { frames.append($0); return nil }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                                  windowNumber: window.windowNumber, context: nil, characters: "😀",
                                                  charactersIgnoringModifiers: "😀", isARepeat: false, keyCode: 0))
        page.keyDown(with: event)
        #expect(!frames.isEmpty)
        #expect(frames.allSatisfy { $0.ch == 0 && $0.unmod == 0 })
    }

    /// The candidate window follows the composition: each push replaces the rects firstRect
    /// answers from, with no request to the host.
    @Test func theFirstRectIsTheLastPushedOne() {
        let (page, window) = makePage()
        defer { window.close() }
        var ops: [ChromiumHostTextInputOp] = []
        page.textInputSink = { ops.append($0) }
        page.applyTextInputState(Self.field)
        page.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        var state = Self.field
        state.composition = 3..<4
        state.compositionRects = [CGRect(x: 30, y: 10, width: 14, height: 16)]
        page.applyTextInputState(state)
        let range = NSRange(location: 3, length: 1)
        // Page (30, 10) top-left, 16 tall, in a 300-tall page at screen (100, 100).
        #expect(page.firstRect(forCharacterRange: range, actualRange: nil)
            == NSRect(x: 130, y: 100 + 300 - 26, width: 14, height: 16))
        state.compositionRects = [CGRect(x: 60, y: 40, width: 14, height: 16)]
        page.applyTextInputState(state)
        #expect(page.firstRect(forCharacterRange: range, actualRange: nil)
            == NSRect(x: 160, y: 100 + 300 - 56, width: 14, height: 16))
        #expect(page.textInput.stats.firstRectAnswers == 2)
        #expect(ops.count == 1)
    }
}
#endif
