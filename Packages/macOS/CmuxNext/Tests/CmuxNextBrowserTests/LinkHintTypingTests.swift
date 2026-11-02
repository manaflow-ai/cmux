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
        var held = LinkHintHeldKeys<Character>()
        for key in "ieldkeysok" { held.hold(key) }
        #expect(String(held.release(after: .passThrough)) == "ieldkeysok", "keys typed during the page's answer were lost or reordered")
        #expect(held.release(after: .passThrough).isEmpty, "a held key went to the page twice")
    }

    /// Lead review of #32537, case 2 (no text field has the keyboard, link hints start): the letters typed before the
    /// labels show are hint keys, checked when the labels show; none reaches the page (a page shortcut on the same
    /// letter would run).
    @Test func hintLettersTypedBeforeTheLabelsShowPickAndNeverReachThePage() {
        var session = LinkHintSession(mode: .follow)
        var held = LinkHintHeldKeys<Character>()
        let targets = (0..<30).map { LinkHintTarget(x: Double($0), y: 1, left: Double($0), top: 0) }
        let label = Array(LinkHintSession.labels(count: targets.count))[7]
        for key in label { held.hold(key); _ = session.type(String(key)) }
        let outcome = session.show(targets, editing: false)
        #expect(outcome == .pick(targets[7]), "the letters typed before the labels showed did not pick: \(outcome)")
        #expect(held.release(after: outcome).isEmpty, "a hint letter reached the page")
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
