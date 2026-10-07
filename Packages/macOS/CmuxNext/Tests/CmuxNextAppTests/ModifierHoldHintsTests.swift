import AppKit
import Testing
@testable import CmuxNextApp

@Suite("Intentional modifier hold hints")
struct ModifierHoldHintsTests {
    @Test func waitsForAnIntentionalHold() {
        var policy = ShortcutHintModifierPolicy()
        let visible1 = policy.update(flags: .command, eligible: true, elapsed: .milliseconds(299))
        #expect(!visible1)
        let visible2 = policy.update(flags: .command, eligible: true, elapsed: .milliseconds(300))
        #expect(visible2)
        let visible3 = policy.update(flags: [], eligible: true, elapsed: .seconds(1))
        #expect(!visible3)
        let visible4 = policy.update(flags: .control, eligible: true, elapsed: .milliseconds(300))
        #expect(visible4)
    }

    @Test func typingSuppressesHintsUntilModifiersAreReleased() {
        var policy = ShortcutHintModifierPolicy()
        _ = policy.update(flags: .command, eligible: true, elapsed: .zero)
        policy.keyDown()
        let visible5 = policy.update(flags: .command, eligible: true, elapsed: .seconds(1))
        #expect(!visible5)
        let visible6 = policy.update(flags: [], eligible: true, elapsed: .zero)
        #expect(!visible6)
        let visible7 = policy.update(flags: .command, eligible: true, elapsed: .milliseconds(300))
        #expect(visible7)
    }

    @Test func unmodifiedTypingDoesNotSuppressTheNextHold() {
        var policy = ShortcutHintModifierPolicy()
        _ = policy.update(flags: [], eligible: true, elapsed: .zero)
        policy.keyDown()
        let visible = policy.update(flags: .control, eligible: true, elapsed: .milliseconds(300))
        #expect(visible)
    }

    @Test func onlyTheKeyWindowMayShowHints() {
        var policy = ShortcutHintModifierPolicy()
        let visible8 = policy.update(flags: .control, eligible: false, elapsed: .seconds(1))
        #expect(!visible8)
        let visible9 = policy.update(flags: [.command, .option], eligible: true, elapsed: .seconds(1))
        #expect(!visible9)
        let visible10 = policy.update(flags: [.control, .shift], eligible: true, elapsed: .seconds(1))
        #expect(!visible10)
    }
}
