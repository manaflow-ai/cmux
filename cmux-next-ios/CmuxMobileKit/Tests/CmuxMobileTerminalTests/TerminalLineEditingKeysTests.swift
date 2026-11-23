import Foundation
import Testing
@testable import CmuxMobileTerminal

/// A hardware keyboard's Cmd-Backspace, Cmd-Left / Right and Option-Left / Right send what the Mac
/// terminal sends (Ghostty's macOS defaults): ^U, ^A, ^E, ESC b and ESC f.
@Suite struct TerminalLineEditingKeysTests {
    static let cases: [(usage: UInt16, mods: TerminalKeyMods, letter: String, sent: TerminalKeyMods)] = [
        (TerminalHIDUsage.backspace, .command, "u", .control),
        (TerminalHIDUsage.left, .command, "a", .control),
        (TerminalHIDUsage.right, .command, "e", .control),
        (TerminalHIDUsage.left, .alternate, "b", .alternate),
        (TerminalHIDUsage.right, .alternate, "f", .alternate),
    ]

    @Test(arguments: 0..<cases.count)
    func eachChordSendsItsLetter(index: Int) throws {
        let entry = Self.cases[index]
        let actions = try #require(TerminalInputRouter.lineEditing(usage: entry.usage, mods: entry.mods))
        #expect(actions.count == 2)
        guard case .key(let press) = actions[0], case .key(let release) = actions[1] else {
            Issue.record("\(entry.letter): not a key press and release")
            return
        }
        #expect(press.isPress && !release.isPress)
        #expect(press.text == entry.letter)
        #expect(press.mods == entry.sent, "never a Command (super) key")
        #expect(press.keyCode == TerminalHIDUsage.ghosttyKeyCode(TerminalHIDUsage.usage(forASCII: Character(entry.letter)) ?? 0))
    }

    @Test func otherKeysAndModifiersAreNotLineEditing() {
        #expect(TerminalInputRouter.lineEditing(usage: TerminalHIDUsage.up, mods: .command) == nil)
        #expect(TerminalInputRouter.lineEditing(usage: TerminalHIDUsage.left, mods: [.command, .shift]) == nil)
        #expect(TerminalInputRouter.lineEditing(usage: TerminalHIDUsage.left, mods: []) == nil)
        #expect(TerminalInputRouter.lineEditing(usage: TerminalHIDUsage.backspace, mods: .alternate) == nil)
    }

    @Test func hardwareCommandBackspaceIsHandledNotGivenToUIKit() {
        var router = TerminalInputRouter()
        let press = router.pressBegan(usage: TerminalHIDUsage.backspace, mods: .command, characters: "", unmodified: "")
        guard case .handled(let actions) = press, case .key(let event)? = actions.first else {
            Issue.record("Cmd-Backspace went to UIKit: \(press)")
            return
        }
        #expect(actions.count == 1, "the press only; pressEnded sends the release")
        #expect(event.text == "u" && event.mods == .control)
        #expect(router.pressEnded(actions).count == 1)
    }

    @Test func otherCommandKeysStayWithUIKit() {
        var router = TerminalInputRouter()
        #expect(router.pressBegan(usage: 0x19, mods: .command, characters: "v", unmodified: "v") == .system)
    }
}
