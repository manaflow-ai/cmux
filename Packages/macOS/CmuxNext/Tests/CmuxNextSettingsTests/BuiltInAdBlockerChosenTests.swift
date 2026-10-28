import CmuxNextSettings
import Testing

/// `browser.builtInAdBlocker` set to `true` is the person's choice: on a Chromium fork without the first-tab load the
/// built-in ad blocker then still loads at start. Unset is on by default, not chosen (first-seconds bench, 2026-10-28).
struct BuiltInAdBlockerChosenTests {
    private static func snapshot(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["browser": .object(["builtInAdBlocker": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func unsetIsOnButNotChosen() {
        let snapshot = Self.snapshot(nil)
        #expect(snapshot.browserBuiltInAdBlocker)
        #expect(!snapshot.browserBuiltInAdBlockerChosen)
    }

    @Test func trueIsChosen() {
        #expect(Self.snapshot(.bool(true)).browserBuiltInAdBlockerChosen)
    }

    @Test func falseOrNotABoolIsNotChosen() {
        #expect(!Self.snapshot(.bool(false)).browserBuiltInAdBlockerChosen)
        #expect(!Self.snapshot(.string("yes")).browserBuiltInAdBlockerChosen)
    }
}
