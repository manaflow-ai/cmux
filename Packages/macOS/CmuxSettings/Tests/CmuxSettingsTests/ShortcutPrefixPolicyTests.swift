import Testing
@testable import CmuxSettings

@Suite("Shortcut prefix policy")
struct ShortcutPrefixPolicyTests {
    @Test func acceptsOnlyOneSupportedLeaderStroke() {
        let policy = ShortcutPrefixPolicy()
        #expect(policy.result(for: .unbound) == .unbound)
        #expect(policy.normalized(ShortcutStroke(key: "b")) == nil)
        #expect(policy.normalized(ShortcutStroke(key: "space")) == ShortcutStroke(key: "space"))
        #expect(
            policy.normalized(ShortcutStroke(key: "b", control: true, keyCode: 11))
                == ShortcutStroke(key: "b", control: true, keyCode: 11)
        )
        #expect(policy.normalized(ShortcutStroke(key: "")) == nil)
    }

    @Test(arguments: [
        ShortcutStroke(key: "b"),
        ShortcutStroke(key: "escape", control: true),
        ShortcutStroke(key: "media.volumeUp", command: true),
        ShortcutStroke(key: "volumeUp", command: true),
    ])
    func rejectsUnsupportedStrokes(_ stroke: ShortcutStroke) {
        #expect(ShortcutPrefixPolicy().normalized(stroke) == nil)
    }

    @Test func rejectsChordsAndMalformedEmptyStrokes() {
        let policy = ShortcutPrefixPolicy()
        let chord = StoredShortcut(
            first: ShortcutStroke(key: "b", control: true),
            second: ShortcutStroke(key: "c")
        )
        #expect(policy.normalized(chord) == nil)
        let malformed = StoredShortcut(
            first: ShortcutStroke(key: ""),
            second: ShortcutStroke(key: "c")
        )
        #expect(policy.result(for: malformed) == .emptyStrokeNotSupported)
        #expect(policy.normalized(malformed) == nil)
    }
}
