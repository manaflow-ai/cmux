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

    /// Lead review of #32537, case 1 (a text field has the keyboard): every key typed while the page answered goes to
    /// the field, once each, in the order typed; the `f` that started the session reached it first (the page sees a
    /// letter before cmux hears it was unhandled).
    @Test func keysTypedWhileThePageAnswersGoToTheTextFieldOnceInOrder() {
        var held = LinkHintHeldKeys<Character>(startedAt: 10)
        for key in "ieldkeysok" { held.hold(key, typedAt: 11) }
        #expect(String(held.release(after: .passThrough)) == "ieldkeysok", "keys typed during the page's answer were lost or reordered")
        #expect(held.release(after: .passThrough).isEmpty, "a held key went to the page twice")
    }

    /// Lead review of #32537, case 2 (no text field has the keyboard, link hints start): the letters typed before the
    /// labels show are hint keys, checked when the labels show; none reaches the page (a page shortcut on the same
    /// letter would run).
    @Test func hintLettersTypedBeforeTheLabelsShowPickAndNeverReachThePage() {
        var session = LinkHintSession(mode: .follow)
        var held = LinkHintHeldKeys<Character>(startedAt: 10)
        let targets = (0..<30).map { LinkHintTarget(x: Double($0), y: 1, left: Double($0), top: 0) }
        let label = Array(LinkHintSession.labels(count: targets.count))[7]
        for key in label { held.hold(key, typedAt: 11); _ = session.type(String(key)) }
        let outcome = session.show(targets, editing: false)
        #expect(outcome == .pick(targets[7]), "the letters typed before the labels showed did not pick: \(outcome)")
        #expect(held.release(after: outcome).isEmpty, "a hint letter reached the page")
    }

    /// v5 of #32537 looped without end (REOPEN VIDEO, ~32,000 key-downs per round): the keys link hints sent back to
    /// the page went through the key route again, were held by the next session and sent again. A key sent back is
    /// let through once and never taken again; the keys that reach the page equal the keys typed.
    @Test func aKeySentBackToThePageIsLetThroughOnceAndNeverTakenAgain() {
        final class Key {}
        let typed = (0..<10).map { _ in Key() }
        var held = LinkHintHeldKeys<Key>(startedAt: 10)
        var replays = LinkHintReplays<Key>()
        typed.forEach { held.hold($0, typedAt: 11) }
        let sent = held.release(after: .passThrough)
        replays.mark(sent)
        var passed = 0, passedAgain = 0
        for key in sent where replays.isReplay(key) { passed += 1 }
        for key in sent where replays.isReplay(key) { passedAgain += 1 }
        let stranger = replays.isReplay(Key())
        #expect(passed == typed.count, "a key sent back to the page was taken again: \(typed.count - passed) of \(typed.count)")
        #expect(passedAgain == 0, "a key sent back was let through twice")
        #expect(!stranger, "a key never sent back was let through")
    }

    /// v6 of #32537 doubled the first letters (REOPEN VIDEO 7710: "fieldfieldkeysok", "ffieldkeysok"): a key the page
    /// already had (typed before the session started: the `f`, and the letters typed before the page reported the `f`)
    /// came through the key route again while the session collected, was held, and was sent back. A key typed before
    /// the session started is never sent back; the keys the PAGE receives equal the keys typed, once each, in order.
    @Test func aKeyThePageAlreadyHadIsNeverSentBack() {
        let typed = Array("fieldkeysok")
        var page: [Character] = Array("fiel") // delivered before the session started at t = 10
        var held = LinkHintHeldKeys<Character>(startedAt: 10)
        for (index, key) in "fiel".enumerated() { held.hold(key, typedAt: 9 + Double(index) / 100) } // the same keys, again
        for key in "dkeysok" { held.hold(key, typedAt: 11) }
        page += held.release(after: .passThrough)
        #expect(page == typed, "the page got \(String(page)), not \(String(typed))")
    }

    @Test func aSessionWhosePageIsNotEditingStillLabelsAndPicks() {
        var session = LinkHintSession(mode: .follow)
        let outcome = session.show([Self.field], editing: false)
        #expect(outcome != .passThrough && outcome != .cancel)
    }

    /// The collect script answers whether a text field has the keyboard next to its targets; an older answer (targets
    /// only) is read as not editing.
    @Test func theCollectAnswerSaysWhetherATextFieldHasTheKeyboard() {
        let editing = BrowserJSValue.string(#"{"editing":true,"targets":[{"x":1,"y":2,"left":0,"top":0}]}"#)
        #expect(LinkHintSession.editing(from: editing))
        #expect(LinkHintSession.targets(from: editing).count == 1)
        let idle = BrowserJSValue.string(#"{"editing":false,"targets":[]}"#)
        #expect(!LinkHintSession.editing(from: idle))
        let old = BrowserJSValue.string(#"[{"x":1,"y":2,"left":0,"top":0}]"#)
        #expect(!LinkHintSession.editing(from: old))
        #expect(LinkHintSession.targets(from: old).count == 1)
    }
}
