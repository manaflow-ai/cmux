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
        for letter in "ieldkeys" { _ = session.type(String(letter)) }
        #expect(session.show([Self.field], editing: true) == .passThrough, "link hints took the letters typed into a text field")
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
