import AppKit
@testable import CmuxNextApp
import CmuxNextInput
import Testing

/// Audit item 1-2 (input-languages-result.md): keys typed before a page can take them were queued as
/// their raw `characters`: a dead key types "" and was not printable, so it dropped the whole queue
/// and lost its accent; with Kotoeri selected, "k a" queued "ka" (romaji), never か.
/// `TypeAheadComposer` queues what the input source types.
@MainActor @Suite struct TypeAheadComposerTests {
    /// AZERTY: the key right of P (keyCode 33) is the dead ^; ^ then e types ê, ^ then Space types ^.
    static let azerty: TypeAheadComposer.Translate = { keyCode, _, state in
        switch (keyCode, state) {
        case (33, 0): state = 1; return ""
        case (14, 1): state = 0; return "ê"
        case (49, 1): state = 0; return "^"
        case (14, _): state = 0; return "e"
        case (8, _): state = 0; return "c"
        case (0, _): state = 0; return "q"
        case (32, _): state = 0; return "u"
        default: state = 0; return "?"
        }
    }

    @Test func aDeadKeyKeepsTheQueueAndComposesWithTheNextKey() {
        var composer = TypeAheadComposer()
        var queued = ""
        for code: UInt16 in [8, 32, 33, 14] {
            switch composer.compose(keyCode: code, modifiers: [], translate: Self.azerty) {
            case .text(let text): queued += text
            case .deadKey: continue
            case .notComposable: Issue.record("a keyboard layout key was not composable")
            }
        }
        #expect(queued == "cuê")
        #expect(composer.deadKeyState == 0)
    }

    @Test func aDeadKeyThenSpaceTypesTheAccent() {
        var composer = TypeAheadComposer()
        #expect(composer.compose(keyCode: 33, modifiers: [], translate: Self.azerty) == .deadKey)
        #expect(composer.compose(keyCode: 49, modifiers: [], translate: Self.azerty) == .text("^"))
    }

    /// An input method is selected: the composer has no translation, so k and a are never queued as "ka".
    @Test func anInputMethodsKeysAreNeverQueuedAsRawCharacters() {
        var composer = TypeAheadComposer()
        let kotoeri: TypeAheadComposer.Translate = { _, _, _ in nil }
        #expect(composer.compose(keyCode: 40, modifiers: [], translate: kotoeri) == .notComposable)
        #expect(composer.compose(keyCode: 0, modifiers: [], translate: kotoeri) == .notComposable)
    }

    static func key(_ characters: String, ignoring: String, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
                                      characters: characters, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: keyCode))
    }

    /// The router's type-ahead reading of a key: a dead key typed for a page that is not ready is
    /// taken (the queue is kept) and its next key queues ê; with an input method selected, no key
    /// is queued as its raw characters.
    @Test func theRouterQueuesWhatTheInputSourceTypes() throws {
        let router = KeyRouter(registry: .standard())
        router.typeAheadTranslate = Self.azerty
        #expect(router.typeAheadKey(try Self.key("", ignoring: "^", keyCode: 33)) == .deadKey)
        #expect(router.typeAheadKey(try Self.key("e", ignoring: "e", keyCode: 14)) == .text("ê"))

        let kotoeri = KeyRouter(registry: .standard())
        kotoeri.typeAheadTranslate = { _, _, _ in nil }
        #expect(kotoeri.typeAheadKey(try Self.key("k", ignoring: "k", keyCode: 40)) == .notComposable)
    }
}
