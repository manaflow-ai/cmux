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
        for key in "ieldkeysok" { held.hold(key) }
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
        for key in label { held.hold(key); _ = session.type(String(key)) }
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
        typed.forEach { held.hold($0) }
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

    /// The page's side of a key that link hints let through (``LinkHintController`` returns it to AppKit's dispatch):
    /// a key still on its way reaches the page now; a key Chromium sent back after the page had it (its unhandled-key
    /// redispatch, the same event) stays in that redispatch, as with no session, so the page does not get it again.
    private struct Page {
        var received: [Character] = []
        var held: LinkHintHeldKeys<Character>
        /// One key-down through the link-hint intercept while a session collects; `echo` marks Chromium's send-back.
        mutating func keyDown(_ key: Character, typedAt: TimeInterval, echo: Bool = false) {
            switch held.route(typedAt: typedAt) {
            case .page: if !echo { received.append(key) }
            case .session: held.hold(key)
            }
        }
    }

    /// v6 of #32537 doubled the first letters (REOPEN VIDEO 7710: "fieldfieldkeysok", "ffieldkeysok"): Chromium sends a
    /// letter the page left unhandled back through `NSApp.sendEvent` (the same event; a plain letter is not in the
    /// router's `decided`), so the `f` and the letters the page had before the session started came through the
    /// intercept again, were held, and were sent back as new keys. A key typed before the session started is never
    /// the session's: the keys the PAGE receives equal the keys typed, once each, in order.
    @Test func aKeyThePageAlreadyHadIsNeverSentBack() {
        var page = Page(received: Array("fiel"), held: LinkHintHeldKeys(startedAt: 10)) // delivered before the start at t = 10
        for (index, key) in "fiel".enumerated() { page.keyDown(key, typedAt: 9 + Double(index) / 100, echo: true) }
        for key in "dkeysok" { page.keyDown(key, typedAt: 11) }
        page.received += page.held.release(after: .passThrough)
        #expect(String(page.received) == "fieldkeysok", "the page got \(String(page.received)), not fieldkeysok")
    }

    /// Lead on STATUS 7738 (v7 of #32537 dropped it): a key typed before the session started but dispatched after it
    /// (still in the event queue when Chromium's report of the `f` started the session) is no hint key and must not be
    /// lost: it goes on to the page on its normal path, once, before the keys typed after it. Judged by the event's own
    /// time, not the dispatch.
    @Test func aKeyTypedBeforeTheStartButDispatchedAfterItReachesThePageOnce() {
        var page = Page(received: Array("fie"), held: LinkHintHeldKeys(startedAt: 10))
        for (index, key) in "fie".enumerated() { page.keyDown(key, typedAt: 9 + Double(index) / 100, echo: true) }
        page.keyDown("l", typedAt: 9.03) // typed before the start, dispatched after it
        page.keyDown("d", typedAt: 9.04)
        for key in "keysok" { page.keyDown(key, typedAt: 11) }
        let keptBack = page.held.keys.count
        page.received += page.held.release(after: .passThrough)
        #expect(String(page.received) == "fieldkeysok", "the page got \(String(page.received)), not fieldkeysok")
        #expect(keptBack == 6, "the session took a key typed before it started (\(keptBack) held, not 6)")
    }

    /// A key without a time (a synthetic event, timestamp 0) is the session's, so link hints still work for it.
    @Test func aKeyWithoutATimeIsTheSessions() {
        #expect(LinkHintHeldKeys<Character>(startedAt: 10).route(typedAt: 0) == .session)
        #expect(LinkHintHeldKeys<Character>(startedAt: 10).route(typedAt: 10) == .session)
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
