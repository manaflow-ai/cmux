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

    @Test func aLeavingSessionReleasesOnlyItsOwnKeys() throws {
        var held = BrowserReplHeldKeys()
        let shift = try stroke("Shift", "ShiftLeft")
        let a = try stroke("a", "KeyA")
        let b = try stroke("b", "KeyB")
        held.record(shift, keyDown: true, sessionID: "leaving")
        held.record(a, keyDown: true, sessionID: "staying")
        held.record(b, keyDown: true, sessionID: "leaving")
        #expect(held.releaseAll(heldBy: "leaving") == [b, shift])
        #expect(held.strokes == [a], "the staying session lost its key or inherited the leaving one's")
        #expect(held.releaseAll(heldBy: "leaving").isEmpty)
        #expect(held.releaseAll(heldBy: "staying") == [a])
    }
}

/// Keys and buttons a session holds are held in the web view that got the
/// press. When the tab's web view is replaced (a restore, a crash
/// recovery) before an ending session's release lands, the release is
/// forgotten: it never reaches the replacement's page as a trusted event.
@MainActor
@Suite struct BrowserReplInputTargetTests {
    final class View {}

    @Test func aReleaseReachesOnlyTheWebViewThatGotThePress() {
        let pressed = View()
        let replacement = View()
        let target = BrowserReplInputTarget(pressed)
        #expect(target.deliverable(to: pressed) === pressed)
        #expect(target.deliverable(to: replacement) == nil, "a release went to the replacement web view")
        #expect(target.deliverable(to: nil) == nil)
    }

    @Test func aReleaseOfAWebViewThatIsGoneReachesNothing() {
        var pressed: View? = View()
        let target = BrowserReplInputTarget(pressed)
        pressed = nil
        #expect(target.deliverable(to: View()) == nil)
        #expect(BrowserReplInputTarget<View>(nil).deliverable(to: View()) == nil)
    }
}
