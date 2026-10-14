import Testing
@testable import CmuxBrowser

@Suite struct BrowserReplHeldKeysTests {
    private func stroke(_ key: String, _ code: String, _ modifiers: [String] = []) throws -> BrowserReplKeyStroke {
        try #require(BrowserReplKeyStroke.resolve(key: key, code: code, text: nil, modifiers: modifiers))
    }

    @Test func heldKeysReleaseLastPressedFirst() throws {
        var held = BrowserReplHeldKeys()
        let shift = try stroke("Shift", "ShiftLeft")
        let a = try stroke("A", "KeyA", ["Shift"])
        held.record(shift, keyDown: true)
        held.record(a, keyDown: true)
        #expect(held.releaseAll() == [a, shift])
        #expect(held.strokes.isEmpty)
    }

    @Test func releasedKeysAreNotReleasedAgain() throws {
        var held = BrowserReplHeldKeys()
        let a = try stroke("a", "KeyA")
        let b = try stroke("b", "KeyB")
        held.record(a, keyDown: true)
        held.record(b, keyDown: true)
        held.record(a, keyDown: false)
        #expect(held.releaseAll() == [b])
    }

    @Test func autoRepeatKeepsOneEntry() throws {
        var held = BrowserReplHeldKeys()
        let a = try stroke("a", "KeyA")
        held.record(a, keyDown: true)
        held.record(a, keyDown: true)
        #expect(held.strokes == [a])
    }
}
