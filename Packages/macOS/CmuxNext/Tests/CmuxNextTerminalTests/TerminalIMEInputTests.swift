import AppKit
import Carbon.HIToolbox
@testable import CmuxNextTerminal
import Testing

/// The terminal's NSTextInputClient boundary must pass a completed preedit as one text payload,
/// while the Return/control character used to commit it remains owned by the input method.
@Suite
struct TerminalIMEInputTests {
    @Test func completedCjkAndVietnameseTextIsNeverFiltered() {
        for text in ["안녕하세요", "日本語", "你好", "tiếng Việt"] {
            #expect(!GhosttyInput.isComposingControl(text, composing: true), "committed text was filtered: \(text)")
        }
    }

    @Test func composingReturnIsFilteredUntilTheFollowingPlainReturn() {
        #expect(GhosttyInput.isComposingControl("\r", composing: true))
        #expect(!GhosttyInput.isComposingControl("\r", composing: false))
        #expect(GhosttyInput.isComposingControl("\u{1b}", composing: true))
        #expect(!GhosttyInput.isComposingControl("\u{1b}", composing: false))
    }

    @Test func candidateNavigationReplaysOnlyAfterCommit() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)),
                charactersIgnoringModifiers: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)),
                isARepeat: false,
                keyCode: UInt16(kVK_DownArrow),
            ),
        )
        #expect(GhosttyInput.shouldReplayAfterCommit(event))
        let left = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)),
                charactersIgnoringModifiers: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)),
                isARepeat: false,
                keyCode: UInt16(kVK_LeftArrow),
            ),
        )
        #expect(!GhosttyInput.shouldReplayAfterCommit(left))
    }
}
