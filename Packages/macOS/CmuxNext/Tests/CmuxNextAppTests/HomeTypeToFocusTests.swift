import AppKit
@testable import CmuxNextApp
@testable import CmuxNextHome
import CmuxHomeCore
import Testing
import CmuxNextTestSupport

/// Lawrence 2026-10-19: "If I type randomly, or if I focus using Command + Up/Down Arrow key to
/// focus the pane and start typing, it doesn't actually work. I have to click outside, not in the
/// text input area, and start typing for that to work."
///
/// Home's message box is the primary input of a conversation tab (the React Messages page, as the
/// docked Home and the Home tab). Whatever left the keyboard where it is (a
/// pane-focus shortcut from a terminal, the sidebar, app or window activation: no responder; a hidden field),
/// the pane getting focus and the next printable keys must put the text in the box, none lost.
///
/// The two steps run here as the app runs them: the focus applier gives the pane's content its
/// `focusTarget` when the keyboard is outside the pane, then the key dispatcher hands a printable
/// key to the content's primary input when it is ready (`KeyRouter.typesIntoPrimaryInput`), else
/// the window delivers it to its first responder.
@MainActor @Suite(.serialized) struct HomeTypeToFocusTests {
    /// A dead key (Option-E) goes where the next key goes: it composes there.
    @Test func aDeadKeyIsTyping() throws {
        func key(_ characters: String, _ ignoring: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                          characters: characters, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: 14))
        }
        #expect(KeyRouter.isDeadKey(try key("", "e", .option)))
        #expect(!KeyRouter.isDeadKey(try key("e", "e")))
        #expect(!KeyRouter.isDeadKey(try key("", "e", .command)))
        #expect(!KeyRouter.isDeadKey(try key("", String(Character(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!)))))
    }
}
