import AppKit
import Carbon.HIToolbox
@testable import CmuxNextTerminal
import CmuxNextWakeups
import GhosttyNextKit
import Testing

/// T3 of the input model (input-languages.md): each input method's calls for a typed sequence,
/// replayed through a live terminal's own `keyDown` (the input-method seam
/// ``TerminalSurfaceView/inputMethod`` stands in for `interpretKeyEvents`), must give the program
/// the bytes Ghostty's own macOS host gives it (ghostty-next SurfaceView_AppKit.swift keyDown,
/// insertText, setMarkedText): the committed text exactly once, never the preedit, never the
/// key that only changed the composition, and the key itself when the input method lets it pass.
///
/// The traces are what macOS's input methods call on an NSTextInputClient for each key (as
/// AppKit delivers them during `interpretKeyEvents`); a step outside a key (a candidate click,
/// the emoji picker, dictation) calls the view with no key down.
@MainActor @Suite(.serialized)
struct TerminalInputMethodTraceTests {
    /// One input method call.
    enum Call {
        case mark(String)
        case insert(String)
        /// `insertText` of a lone UTF-16 unit (Unicode Hex Input sends a pair as two calls).
        case insertUnit(UInt16)
        case unmark
        case command(Selector)
        /// `insertText` of what the key types after Ghostty's translation mods (option-as-alt), as
        /// a keyboard layout's input method does.
        case insertTranslated
    }

    /// One key down and the calls the input method makes while it interprets it.
    struct Step {
        var key: String
        var keyCode: UInt16
        var modifiers: NSEvent.ModifierFlags = []
        var calls: [Call]
    }

    struct Rig {
        let session: TerminalSession
        let io: ScriptedTerminalIO
        let window: NSWindow
        var view: TerminalSurfaceView { session.surfaceView }

        var written: String { String(decoding: io.writes.reduce(Data(), +), as: UTF8.self) }

        func close() {
            io.finish()
            window.contentView = nil
            window.close()
            session.close()
        }

        /// Plays `steps`: each key goes through the view's `keyDown`, its input method calls run
        /// inside it in order.
        func play(_ steps: [Step]) throws {
            for (index, step) in steps.enumerated() {
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: step.modifiers, timestamp: TimeInterval(index + 1),
                    windowNumber: window.windowNumber, context: nil, characters: step.key,
                    charactersIgnoringModifiers: step.key, isARepeat: false, keyCode: step.keyCode))
                view.inputMethod = { view, translated in Self.run(step.calls, on: view, translated: translated) }
                view.keyDown(with: event)
                view.inputMethod = nil
            }
        }

        /// Calls outside any key down (a candidate click, the emoji picker, dictation).
        func outsideAKey(_ calls: [Call]) {
            Self.run(calls, on: view)
        }

        static func run(_ calls: [Call], on view: TerminalSurfaceView, translated: NSEvent? = nil) {
            let none = NSRange(location: NSNotFound, length: 0)
            for call in calls {
                switch call {
                case .mark(let text):
                    view.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0), replacementRange: none)
                case .insert(let text): view.insertText(text, replacementRange: none)
                case .insertUnit(let unit):
                    // SAFETY: the one-unit array lives for the call; NSString copies its one character.
                    view.insertText(unsafe NSString(characters: [unit], length: 1), replacementRange: none)
                case .unmark: view.unmarkText()
                case .command(let selector): view.doCommand(by: selector)
                case .insertTranslated: view.insertText(translated?.characters ?? "", replacementRange: none)
                }
            }
        }

        /// The bytes the program got, once the input queue drained: the first write (up to 5 s), then
        /// no new write for 100 ms. A test that expects nothing written waits the 2 s window instead.
        func settle(expectingWrites: Bool = true) async throws {
            if expectingWrites {
                let first = ContinuousClock.now + .seconds(5)
                while io.writes.isEmpty, ContinuousClock.now < first { try await Task.sleep(for: .milliseconds(20)) }
            }
            let deadline = ContinuousClock.now + .seconds(2)
            var last = -1
            while ContinuousClock.now < deadline {
                let count = io.writes.count
                if count == last { break }
                last = count
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    static func rig() throws -> Rig {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.view
        session.view.frame = NSRect(x: 0, y: 0, width: 480, height: 240)
        session.view.layoutSubtreeIfNeeded()
        window.makeFirstResponder(session.surfaceView)
        return Rig(session: session, io: io, window: window)
    }

    // MARK: Japanese (Kotoeri Romaji)

    /// k a -> か (preedit), Space converts (preedit 下), Return commits: the program gets 下 once,
    /// no "ka", no Space, no Return.
    @Test func kotoeriConvertAndCommit() async throws {
        let rig = try Self.rig()
        defer { rig.close() }
        try rig.play([
            Step(key: "k", keyCode: UInt16(kVK_ANSI_K), calls: [.mark("k")]),
            Step(key: "a", keyCode: UInt16(kVK_ANSI_A), calls: [.mark("か")]),
            Step(key: " ", keyCode: UInt16(kVK_Space), calls: [.mark("下")]),
            Step(key: "\r", keyCode: UInt16(kVK_Return), calls: [.insert("下")]),
        ])
        try await rig.settle()
        #expect(rig.written == "下", "got \(rig.written.debugDescription)")
        #expect(!rig.view.hasMarkedText())
    }

    /// Ctrl-J (to hiragana) and Backspace while composing belong to Kotoeri; Backspace that empties
    /// the preedit deletes nothing the program had.
    @Test func kotoeriControlKeysAndBackspaceStayInTheInputMethod() async throws {
        let rig = try Self.rig()
        defer { rig.close() }
        try rig.play([
            Step(key: "k", keyCode: UInt16(kVK_ANSI_K), calls: [.mark("k")]),
            Step(key: "a", keyCode: UInt16(kVK_ANSI_A), calls: [.mark("か")]),
            Step(key: "\u{0A}", keyCode: UInt16(kVK_ANSI_J), modifiers: [.control], calls: [.mark("か")]),
            Step(key: "\u{7F}", keyCode: UInt16(kVK_Delete), calls: [.unmark]),
        ])
        try await rig.settle(expectingWrites: false)
        #expect(rig.written.isEmpty, "the program got \(rig.written.debugDescription) from keys Kotoeri took")
    }

    /// A key the input method lets pass (no preedit: Return is `insertNewline:`) reaches the program itself.
    @Test func aKeyTheInputMethodPassesReachesTheProgram() async throws {
        let rig = try Self.rig()
        defer { rig.close() }
        try rig.play([Step(key: "\r", keyCode: UInt16(kVK_Return), calls: [.command(#selector(NSResponder.insertNewline(_:)))])])
        try await rig.settle()
        #expect(rig.written == "\r", "got \(rig.written.debugDescription)")
    }

    // MARK: Chinese (Pinyin)

    /// n i h a o, then 1 picks the first candidate 你好: one commit, no digit.
    @Test func pinyinDigitSelectsACandidate() async throws {
        let rig = try Self.rig()
        defer { rig.close() }
        let letters: [(String, Int)] = [("n", kVK_ANSI_N), ("i", kVK_ANSI_I), ("h", kVK_ANSI_H), ("a", kVK_ANSI_A), ("o", kVK_ANSI_O)]
        var preedit = ""
        var steps: [Step] = []
        for (letter, code) in letters {
            preedit += letter
            steps.append(Step(key: letter, keyCode: UInt16(code), calls: [.mark(preedit)]))
        }
        steps.append(Step(key: "1", keyCode: UInt16(kVK_ANSI_1), calls: [.insert("你好")]))
        try rig.play(steps)
        try await rig.settle()
        #expect(rig.written == "你好", "got \(rig.written.debugDescription)")
    }

    // MARK: Korean (2-Set)

    /// ㅎ ㅏ ㄴ -> 한 (preedit), then Right commits 한 and still moves the cursor (the arrow's
    /// sequence after the text, as upstream replays it).
    @Test func koreanCommitsOnAnArrowAndReplaysIt() async throws {
        let rig = try Self.rig()
        defer { rig.close() }
        try rig.play([
            Step(key: "ㅎ", keyCode: UInt16(kVK_ANSI_G), calls: [.mark("ㅎ")]),
            Step(key: "ㅏ", keyCode: UInt16(kVK_ANSI_K), calls: [.mark("하")]),
            Step(key: "ㄴ", keyCode: UInt16(kVK_ANSI_S), calls: [.mark("한")]),
            Step(key: "\u{F703}", keyCode: UInt16(kVK_RightArrow), calls: [.insert("한")]),
        ])
        try await rig.settle()
        #expect(rig.written == "한\u{1B}[C", "not the commit then the arrow: \(rig.written.debugDescription)")
    }

    /// A syllable then the next consonant: 2-Set commits 한 and starts ㄱ in one key.
    @Test func koreanNextSyllableCommitsThePrevious() async throws {
        let rig = try Self.rig()
        defer { rig.close() }
        try rig.play([
            Step(key: "ㅎ", keyCode: UInt16(kVK_ANSI_G), calls: [.mark("ㅎ")]),
            Step(key: "ㅏ", keyCode: UInt16(kVK_ANSI_K), calls: [.mark("하")]),
            Step(key: "ㄴ", keyCode: UInt16(kVK_ANSI_S), calls: [.mark("한")]),
            Step(key: "ㄱ", keyCode: UInt16(kVK_ANSI_R), calls: [.insert("한"), .mark("ㄱ")]),
        ])
        try await rig.settle()
        #expect(rig.written == "한", "got \(rig.written.debugDescription)")
        #expect(rig.view.hasMarkedText())
    }

    // MARK: Vietnamese (Telex)

    /// a a -> â, then s -> ấ, Space commits it and the Space.
    @Test func telexComposesAndSpaceCommits() async throws {
        let rig = try Self.rig()
        defer { rig.close() }
        try rig.play([
            Step(key: "a", keyCode: UInt16(kVK_ANSI_A), calls: [.mark("a")]),
            Step(key: "a", keyCode: UInt16(kVK_ANSI_A), calls: [.mark("â")]),
            Step(key: "s", keyCode: UInt16(kVK_ANSI_S), calls: [.mark("ấ")]),
            Step(key: " ", keyCode: UInt16(kVK_Space), calls: [.insert("ấ"), .insert(" ")]),
        ])
        try await rig.settle()
        #expect(rig.written == "ấ ", "got \(rig.written.debugDescription)")
    }

    // MARK: Dead keys (US International, ABC Extended)

    /// ' then e on US International: é once. ' then Space: the apostrophe itself.
    @Test func usInternationalDeadKeys() async throws {
        let rig = try Self.rig()
        defer { rig.close() }
        try rig.play([
            Step(key: "", keyCode: UInt16(kVK_ANSI_Quote), calls: [.mark("'")]),
            Step(key: "é", keyCode: UInt16(kVK_ANSI_E), calls: [.insert("é")]),
            Step(key: "", keyCode: UInt16(kVK_ANSI_Quote), calls: [.mark("'")]),
            Step(key: "'", keyCode: UInt16(kVK_Space), calls: [.insert("'")]),
        ])
        try await rig.settle()
        #expect(rig.written == "é'", "got \(rig.written.debugDescription)")
    }

    /// ABC Extended Option-u then o: ö. A dead key then a key it does not combine with: both.
    @Test func abcExtendedDeadKeys() async throws {
        let rig = try Self.rig()
        defer { rig.close() }
        try rig.play([
            Step(key: "", keyCode: UInt16(kVK_ANSI_U), modifiers: [.option], calls: [.mark("¨")]),
            Step(key: "ö", keyCode: UInt16(kVK_ANSI_O), calls: [.insert("ö")]),
            Step(key: "", keyCode: UInt16(kVK_ANSI_U), modifiers: [.option], calls: [.mark("¨")]),
            Step(key: "¨k", keyCode: UInt16(kVK_ANSI_K), calls: [.insert("¨k")]),
        ])
        try await rig.settle()
        #expect(rig.written == "ö¨k", "got \(rig.written.debugDescription)")
    }

    // MARK: Text that comes with no key

    /// The emoji picker, dictation and a candidate click insert with no key down: typed input
    /// (no bracketed paste), exactly once.
    @Test func textWithoutAKeyIsTypedNotPasted() async throws {
        let rig = try Self.rig()
        defer { rig.close() }
        rig.outsideAKey([.insert("😀")])
        rig.outsideAKey([.insert("hello world")])
        try await rig.settle()
        #expect(rig.written == "😀hello world", "got \(rig.written.debugDescription)")
        #expect(!rig.written.contains("\u{1B}[200~"), "inserted text was sent as a bracketed paste")
    }

    /// Unicode Hex Input sends a supplementary character as a lead then a trail unit: one character.
    @Test func unicodeHexInputJoinsSurrogates() async throws {
        let rig = try Self.rig()
        defer { rig.close() }
        // U+1F600 = D83D DE00
        rig.outsideAKey([.insertUnit(0xD83D), .insertUnit(0xDE00)])
        try await rig.settle()
        #expect(rig.written == "😀", "got \(rig.written.debugDescription)")
    }

    // MARK: Switching the input source while composing

    /// The source changes mid-composition (the system ends it: unmark with no key), then plain
    /// keys of the new layout type themselves; the dropped preedit never reaches the program.
    @Test func switchingSourceMidCompositionDropsThePreedit() async throws {
        let rig = try Self.rig()
        defer { rig.close() }
        try rig.play([Step(key: "k", keyCode: UInt16(kVK_ANSI_K), calls: [.mark("k")])])
        rig.outsideAKey([.unmark])
        try rig.play([Step(key: "x", keyCode: UInt16(kVK_ANSI_X), calls: [.insert("x")])])
        try await rig.settle()
        #expect(rig.written == "x", "got \(rig.written.debugDescription)")
    }

    // MARK: Option as Alt

    /// Option-b: Ghostty decides per layout (`macos-option-as-alt` unset: on for US and US
    /// International, off elsewhere, keyboard.zig detectOptionAsAlt). On, the program gets ESC b;
    /// off, the character Option types (∫). Whichever this host's layout gives, the bytes follow
    /// Ghostty's translation mods, never both and never neither.
    @Test func optionFollowsGhosttysTranslationMods() async throws {
        let rig = try Self.rig()
        defer { rig.close() }
        let surface = try #require(rig.view.surface)
        // SAFETY: the rig's live surface.
        let translated = GhosttyInput.flags(unsafe ghostty_surface_key_translation_mods(surface, GhosttyInput.mods([.option])))
        try rig.play([Step(key: "∫", keyCode: UInt16(kVK_ANSI_B), modifiers: [.option], calls: [.insertTranslated])])
        try await rig.settle()
        if translated.contains(.option) {
            #expect(rig.written == "∫", "Option types its character here; got \(rig.written.debugDescription)")
        } else {
            #expect(rig.written == "\u{1B}b", "Option is Alt here; got \(rig.written.debugDescription)")
        }
    }
}
