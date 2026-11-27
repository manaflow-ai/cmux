import Testing
@testable import CmuxBrowser

@Suite struct BrowserReplHeldKeysTests {
    private func stroke(_ key: String, _ code: String, _ modifiers: [String] = []) throws -> BrowserReplKeyStroke {
        try #require(try BrowserReplKeyStroke.resolve(key: key, code: code, text: nil, modifiers: modifiers))
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

/// A session that leaves a tab releases the keys it holds there, and only
/// those: another session that stays keeps its own held keys and inherits
/// none of the leaving session's (a Shift it left down would turn the next
/// session's keys into Shift chords).
@Suite struct BrowserReplHeldKeysBySessionTests {
    private func stroke(_ key: String, _ code: String) throws -> BrowserReplKeyStroke {
        try #require(try BrowserReplKeyStroke.resolve(key: key, code: code, text: nil, modifiers: []))
    }

}

/// Keys and buttons a session holds are held in the web view that got the
/// press. When the tab's web view is replaced (a restore, a crash
/// recovery) before an ending session's release lands, the release is
/// forgotten: it never reaches the replacement's page as a trusted event.
@MainActor
@Suite struct BrowserReplInputTargetTests {
    final class View {}

}
