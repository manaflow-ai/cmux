import AppKit
import Testing
@testable import CmuxNextActions

/// Crash program: the function-key characters no longer force-unwrap their scalar; each
/// still resolves to AppKit's private-use character, never the NUL fallback.
@MainActor @Suite struct CrashLiteralTests {
    @Test func functionKeyCharactersResolve() {
        #expect(Shortcut.upArrowKey == "\u{F700}")
        #expect(Shortcut.downArrowKey == "\u{F701}")
        #expect(Shortcut.leftArrowKey == "\u{F702}")
        #expect(Shortcut.rightArrowKey == "\u{F703}")
        #expect(KeyBindingDefaults.left == "\u{F702}")
        #expect(KeyBindingDefaults.right == "\u{F703}")
        #expect(KeyBindingDefaults.pageUp == "\u{F72C}")
        #expect(KeyBindingDefaults.pageDown == "\u{F72D}")
    }
}
