import AppKit
import Testing
@testable import CmuxNextApp

@Suite("Intentional modifier hold hints")
struct ModifierHoldHintsTests {
    @Test func waitsForAnIntentionalHold() {
        var policy = ShortcutHintModifierPolicy()
        #expect(!policy.update(flags: .command, eligible: true, elapsed: .milliseconds(299)))
        #expect(policy.update(flags: .command, eligible: true, elapsed: .milliseconds(300)))
        #expect(!policy.update(flags: [], eligible: true, elapsed: .seconds(1)))
        #expect(policy.update(flags: .control, eligible: true, elapsed: .milliseconds(300)))
    }

    @Test func typingSuppressesHintsUntilModifiersAreReleased() {
        var policy = ShortcutHintModifierPolicy()
        policy.keyDown()
        #expect(!policy.update(flags: .command, eligible: true, elapsed: .seconds(1)))
        #expect(!policy.update(flags: [], eligible: true, elapsed: .zero))
        #expect(policy.update(flags: .command, eligible: true, elapsed: .milliseconds(300)))
    }

    @Test func onlyTheKeyWindowMayShowHints() {
        var policy = ShortcutHintModifierPolicy()
        #expect(!policy.update(flags: .control, eligible: false, elapsed: .seconds(1)))
        #expect(!policy.update(flags: [.command, .option], eligible: true, elapsed: .seconds(1)))
        #expect(!policy.update(flags: [.control, .shift], eligible: true, elapsed: .seconds(1)))
    }
}
