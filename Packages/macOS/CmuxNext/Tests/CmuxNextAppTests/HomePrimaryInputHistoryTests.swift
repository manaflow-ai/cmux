import AppKit
@testable import CmuxNextApp
import CmuxHomeCore
import Testing
import CmuxNextTestSupport

/// Lawrence 2026-10-19: "Up arrow. You need to do work properly. We need to handle unfocus as well
/// so that, like it is history, this is for the iMessage, chief ui stuff".
///
/// The key dispatcher's one primary-input path (`KeyRouter.typesIntoPrimaryInput` with
/// `PrimaryInputTarget.routesToPrimaryInput`): a plain Up or Down while a Home container has the
/// keyboard outside its message box goes to the box's history (a conversation tab; the Home tab and the docked
/// Home show the React Messages page); the box itself and other text inputs keep their arrows.
/// The recall's content (newest sent message, Down back to the draft) is covered by
/// MessagesLabHomeTests.ComposerHistoryKeysTests.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(2))) struct HomePrimaryInputHistoryTests {
    private static func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [.function, .numericPad]) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: code)!
    }

    @Test func onlyPlainUpAndDownAreHistoryArrows() {
        #expect(KeyRouter.historyArrow(Self.key(126)) == true)
        #expect(KeyRouter.historyArrow(Self.key(125)) == false)
        #expect(KeyRouter.historyArrow(Self.key(126, [.function, .numericPad, .shift])) == nil)
        #expect(KeyRouter.historyArrow(Self.key(126, [.function, .numericPad, .command])) == nil)
        #expect(KeyRouter.historyArrow(Self.key(126, [.function, .numericPad, .option])) == nil)
        #expect(KeyRouter.historyArrow(Self.key(126, [.function, .numericPad, .control])) == nil)
        #expect(KeyRouter.historyArrow(Self.key(123)) == nil)
    }
}

/// A card button that takes the keyboard whatever Full Keyboard Access says (an `NSButton` does only with it on).
private final class CardButton: NSView {
    override var acceptsFirstResponder: Bool { true }
}
