@testable import CmuxNextBrowser
import Foundation
import Testing

/// browser-click-then-type (STATUS 7518, VERDICT app): on a page loaded from the address bar whose text field has the
/// keyboard, typing "fieldkeysok" left "fok" in the field and the page logged a click. Chromium reported the `f` as a
/// key no editable field took (its editable-focus flag was stale after the load), so `f` started link hints: the
/// session took the next letters as hint keys, picked the field and clicked it. The page itself is the judge: a link
/// hint session whose page has a text field with the keyboard ends, and the letters typed meanwhile go to the field.
struct LinkHintTypingTests {
    private static let field = LinkHintTarget(x: 520, y: 165, left: 216, top: 146)

    @Test func aSessionWhosePageIsEditingEndsAndPassesItsLettersOn() {
        var session = LinkHintSession(mode: .follow)
        #expect(session.show([Self.field], editing: true) == .passThrough, "link hints took the letters typed into a text field")
    }

    /// A key event of a test: its text, `down` or up, and its key code.
    private final class Key: CustomStringConvertible {
        let text: String, down: Bool, code: UInt16
        init(_ text: String, down: Bool = true, code: UInt16 = 0) { (self.text, self.down, self.code) = (text, down, code) }
        var description: String { down ? text : "^\(text)" }
        var kind: LinkHintPendingKeys<Key>.Kind {
            switch text {
            case "<esc>": .escape
            case "<bs>": .backspace
            default: text.count == 1 && text.unicodeScalars.allSatisfy { ("a"..."z").contains($0) } ? .letter(text) : .other
            }
        }
    }

    /// `text` as typed: each key's down then its up, letters as letters, `<esc>`, `<bs>`, and any other text as another key.
    private static func typing(_ texts: [String]) -> [Key] {
        texts.enumerated().flatMap { index, text in [Key(text, code: UInt16(index + 1)), Key(text, down: false, code: UInt16(index + 1))] }
    }

    /// Holds `keys` as the controller does while the page answers: each key-down, and a key-up when its down is held.
    private static func held(_ keys: [Key]) -> (LinkHintPendingKeys<Key>, passedUps: [Key]) {
        var pending = LinkHintPendingKeys<Key>()
        var passed: [Key] = []
        for key in keys {
            if key.down { pending.hold(key, kind: key.kind, code: key.code) } else if !pending.holdUp(key, code: key.code) { passed.append(key) }
        }
        return (pending, passed)
    }

    private static func letters(_ word: String) -> [String] { word.map(String.init) }

    /// Lead review of #32537, case 1 (a text field has the keyboard): every key typed while the page answers goes to the
    /// field once, in the order typed, whatever it is (a space, a digit, Return, Escape, a chord), each key-up after its
    /// key-down. Review of #32537: a non-letter key typed then ended the session and threw the held letters away.
    @Test func keysTypedWhileThePageAnswersGoToTheTextFieldOnceInOrder() {
        let typed = Self.typing(Self.letters("ield") + [" ", "2", "<return>", "<esc>", "<cmd-a>"] + Self.letters("ok"))
        var (pending, passed) = Self.held(typed)
        var session = LinkHintSession(mode: .follow)
        let resolved = pending.resolve(&session, targets: [Self.field], editing: true)
        #expect(resolved.outcome == .passThrough)
        #expect(passed.isEmpty, "a key-up went to the page before its key-down: \(passed)")
        #expect(resolved.page.map(\.description) == typed.map(\.description), "the page got \(resolved.page), not \(typed)")
        let again = pending.resolve(&session, targets: [Self.field], editing: true).page
        #expect(again.isEmpty, "a held key went to the page twice")
    }

    /// Lead review of #32537, case 2 (no text field has the keyboard, link hints start): the letters typed before the
    /// labels show are hint keys, checked when the labels show; none reaches the page (a page shortcut on the same
    /// letter would run). Keys typed after the pick are the page's again, in order.
    @Test func hintLettersTypedBeforeTheLabelsShowPickAndNeverReachThePage() {
        let targets = (0..<30).map { LinkHintTarget(x: Double($0), y: 1, left: Double($0), top: 0) }
        let label = Array(LinkHintSession.labels(count: targets.count))[7]
        var (pending, _) = Self.held(Self.typing(Self.letters(label) + ["x", "1"]))
        var session = LinkHintSession(mode: .follow)
        let resolved = pending.resolve(&session, targets: targets, editing: false)
        #expect(resolved.outcome == .pick(targets[7]), "the letters typed before the labels showed did not pick: \(resolved.outcome)")
        #expect(resolved.page.map(\.description) == ["x", "^x", "1", "^1"], "the page got \(resolved.page)")
    }

    /// Review of #32537 (no text field): a key that is no hint key, typed while the page answers, ends the session as it
    /// does once labels show; it and every key after it reach the page in order, and the hint letters before it do not.
    /// Escape ends the session and is its own.
    @Test func aKeyThatIsNoHintKeyEndsTheSessionAndReachesThePageWithTheKeysAfterIt() {
        let targets = (0..<30).map { LinkHintTarget(x: Double($0), y: 1, left: Double($0), top: 0) }
        var (pending, _) = Self.held(Self.typing(["a", " ", "x"]))
        var session = LinkHintSession(mode: .follow)
        let resolved = pending.resolve(&session, targets: targets, editing: false)
        #expect(resolved.outcome == .cancel)
        #expect(resolved.page.map(\.description) == [" ", "^ ", "x", "^x"], "the page got \(resolved.page)")
        var (escaped, _) = Self.held(Self.typing(["a", "<esc>", "x"]))
        var other = LinkHintSession(mode: .follow)
        let ended = escaped.resolve(&other, targets: targets, editing: false)
        #expect(ended.outcome == .cancel && ended.page.map(\.description) == ["x", "^x"], "Escape: the page got \(ended.page)")
    }

    /// No links and no text field: the hint letters typed meanwhile are the session's (as when its notice shows); a key
    /// that is no hint key and the keys after it reach the page.
    @Test func withNothingToLabelTheKeysAfterTheFirstNonHintKeyReachThePage() {
        var (pending, _) = Self.held(Self.typing(["a", "b", "<return>", "c"]))
        var session = LinkHintSession(mode: .follow)
        let resolved = pending.resolve(&session, targets: [], editing: false)
        #expect(resolved.noLinks && resolved.outcome == .cancel)
        #expect(resolved.page.map(\.description) == ["<return>", "^<return>", "c", "^c"], "the page got \(resolved.page)")
    }

    /// Review of #32537: the session ended before its page answered (a click, the keyboard left the page, the page call
    /// failed or took past its bound). Nothing decided the keys, so none is lost: every held key reaches the page, in
    /// order, each key-up after its key-down.
    @Test func anEndBeforeThePageAnsweredGivesEveryHeldKeyToThePageInOrder() {
        let typed = Self.typing(Self.letters("ield") + [" ", "<esc>"])
        var (pending, _) = Self.held(typed)
        let released = pending.releaseAll(), releasedAgain = pending.releaseAll()
        #expect(released.map(\.description) == typed.map(\.description))
        #expect(releasedAgain.isEmpty && pending.isEmpty, "a held key went to the page twice")
    }

    /// A key-up whose key-down was not held (typed before the session) goes on at once: it is held only with its down.
    @Test func aKeyUpIsHeldOnlyWithItsKeyDown() {
        var pending = LinkHintPendingKeys<Key>()
        let foreignUp = pending.holdUp(Key("f", down: false, code: 3), code: 3)
        #expect(!foreignUp, "the up of a key the page already had was held")
        pending.hold(Key("i", code: 4), kind: .letter("i"), code: 4)
        let up = pending.holdUp(Key("i", down: false, code: 4), code: 4), secondUp = pending.holdUp(Key("i", down: false, code: 4), code: 4)
        #expect(up)
        #expect(!secondUp, "a second up of one held down was held")
    }

    /// Review of #32537 (v7 judged by the session's start time, so a hint letter typed after the `f` but still queued
    /// when the session started reached the page): a key is the session's unless the app already dispatched it. Chromium
    /// sends a key the page left unhandled through the app again (v6 doubled "fiel"): the same event, or a copy with the
    /// same time, code and characters. A synthetic key (no time) is known by its identity only.
    @Test func aKeyIsTheSessionsUnlessTheAppAlreadyDispatchedIt() {
        var seen = LinkHintSeenKeys()
        let f = Key("f", code: 3), i = Key("i", code: 34)
        func note(_ key: Key, _ time: TimeInterval) -> Bool { seen.note(key, time: time, code: key.code) }
        let firstF = note(f, 9.00), firstI = note(i, 9.01)
        let backF = note(f, 9.00), copyI = note(Key("i", code: 34), 9.01), queuedE = note(Key("e", code: 14), 9.02)
        #expect(!firstF && !firstI, "a key the app never dispatched counts as seen")
        #expect(backF, "Chromium's send-back of the `f` the page had was not known")
        #expect(copyI, "a copy of a key the page had (same time and key code) was not known")
        #expect(!queuedE, "a hint letter still queued at the session start was taken as the page's")
        let synthetic = Key("a")
        let firstA = note(synthetic, 0), otherA = note(Key("a"), 0), backA = note(synthetic, 0)
        #expect(!firstA && !otherA, "two synthetic keys were one")
        #expect(backA)
    }

    /// Lead on STATUS 7898: two identical keys typed in one display refresh ("ll" at 120 Hz) have the same key code and
    /// characters. Their event times differ (the HID event's own time, nanoseconds since boot, as seconds: a Double
    /// holds 0.1 ns at a 5-day uptime), so neither is taken as the other's copy. Chromium's send-back of each is known.
    @Test func twoIdenticalKeysInOneRefreshAreTwoKeys() {
        var seen = LinkHintSeenKeys()
        let uptime: TimeInterval = 432_000.123_456_789
        let first = Key("l", code: 37), second = Key("l", code: 37)
        let l1 = seen.note(first, time: uptime, code: 37), l2 = seen.note(second, time: uptime + 0.004, code: 37), l3 = seen.note(Key("l", code: 37), time: uptime + 0.004_001, code: 37)
        let back1 = seen.note(Key("l", code: 37), time: uptime, code: 37), back2 = seen.note(Key("l", code: 37), time: uptime + 0.004, code: 37)
        #expect(!l1, "the first l counts as seen")
        #expect(!l2, "the second l, 4 ms later, was taken as the first one's copy")
        #expect(!l3, "an l 1 µs after the second was taken as its copy")
        #expect(back1 && back2,
                "Chromium's send-back of an l the page had was not known")
    }

    /// v5 of #32537 looped without end (REOPEN VIDEO, ~32,000 key-downs per round): the keys link hints sent back to
    /// the page went through the key route again, were held by the next session and sent again. A key sent back is
    /// let through once and never taken again; the keys that reach the page equal the keys typed.
    @Test func aKeySentBackToThePageIsLetThroughOnceAndNeverTakenAgain() {
        let typed = (0..<10).map { Key("k", code: UInt16($0)) }
        var pending = LinkHintPendingKeys<Key>()
        var replays = LinkHintReplays<Key>()
        typed.forEach { pending.hold($0, kind: .letter("k"), code: $0.code) }
        var session = LinkHintSession(mode: .follow)
        let sent = pending.resolve(&session, targets: [Self.field], editing: true).page
        replays.mark(sent)
        var passed = 0, passedAgain = 0
        for key in sent where replays.isReplay(key) { passed += 1 }
        for key in sent where replays.isReplay(key) { passedAgain += 1 }
        let stranger = replays.isReplay(Key("k"))
        #expect(passed == typed.count, "a key sent back to the page was taken again: \(typed.count - passed) of \(typed.count)")
        #expect(passedAgain == 0, "a key sent back was let through twice")
        #expect(!stranger, "a key never sent back was let through")
    }

    @Test func aSessionWhosePageIsNotEditingStillLabelsAndPicks() {
        var session = LinkHintSession(mode: .follow)
        let outcome = session.show([Self.field], editing: false)
        #expect(outcome != .passThrough && outcome != .cancel)
    }

    /// The collect script answers whether a text field has the keyboard next to its targets, the focus check (lead on
    /// STATUS 7898: read the focused element first, the targets only when hints start) with no targets; an older answer
    /// (targets only) is read as not editing.
    @Test func theCollectAnswerSaysWhetherATextFieldHasTheKeyboard() {
        let editing = BrowserJSValue.string(#"{"editing":true,"targets":[{"x":1,"y":2,"left":0,"top":0}]}"#)
        #expect(LinkHintSession.editing(from: editing))
        #expect(LinkHintSession.targets(from: editing).count == 1)
        let idle = BrowserJSValue.string(#"{"editing":false,"targets":[]}"#)
        #expect(!LinkHintSession.editing(from: idle))
        let focusOnly = BrowserJSValue.string(#"{"editing":true}"#)
        #expect(LinkHintSession.editing(from: focusOnly), "the focus check's answer (no targets) was read as not editing")
        #expect(!LinkHintSession.editing(from: .string(#"{"editing":false}"#)))
        let old = BrowserJSValue.string(#"[{"x":1,"y":2,"left":0,"top":0}]"#)
        #expect(!LinkHintSession.editing(from: old))
        #expect(LinkHintSession.targets(from: old).count == 1)
    }
}
