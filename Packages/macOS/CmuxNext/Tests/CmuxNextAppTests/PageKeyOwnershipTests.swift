import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextPages
import Testing

/// Pages that own keys (R59 with hq-48, R127):
/// - Bare keys (no Command, Control or Option: j, k, G, /) run cmux
///   bindings only while the focused page declares a context that owns them
///   (the diff viewer, `diffViewerFocused`) and no text field in it has the
///   keyboard; everywhere else they are typing.
/// - In the code editor page (`codeEditorFocused`) Monaco's editing chords
///   win over the app chords that share them (Cmd-D, Opt-Cmd-Up, ...); the
///   app-global chords (Cmd-T, Cmd-W, Cmd-1…9) stay the app's.
@MainActor
struct PageKeyOwnershipTests {
    static func key(_ chars: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    static func context(page: String?, editing: Bool = false) -> KeyContext {
        KeyRouter.keyContext(for: FocusState(), appContext: [], facts: KeyRouter.Facts(pageID: page, pageEditableFocused: editing))
    }

    @Test func pagesDeclareTheirContexts() {
        #expect(Self.context(page: "cmux.diff").bits.contains(.diffViewerFocused))
        #expect(Self.context(page: "cmux.editor").bits.contains(.codeEditorFocused))
        #expect(!Self.context(page: "cmux.markdown").bits.contains(.diffViewerFocused))
        #expect(Self.context(page: "cmux.diff", editing: true)[KeyContext.textInputFocus] == .bool(true))
    }

    @Test func bareKeysRunOnlyInAnOwningPageWithoutATextField() {
        let services = KeyOwnershipMatrixTests.services()
        services.registry.bind("diffViewerNextLine") {}
        let router = services.keyRouter
        let j = Self.key("j", code: 38)
        #expect(router.bareKeyWinner(j, context: Self.context(page: "cmux.diff"))?.command == "diffViewerNextLine")
        #expect(router.bareKeyWinner(j, context: Self.context(page: "cmux.diff", editing: true)) == nil, "a text field types j")
        #expect(router.bareKeyWinner(j, context: Self.context(page: "cmux.markdown")) == nil, "no owner, no bare key")
        #expect(router.bareKeyWinner(j, context: Self.context(page: nil)) == nil)
        #expect(router.bareKeyWinner(Self.key("j", code: 38, .command), context: Self.context(page: "cmux.diff")) == nil, "a chord is not bare")
    }

    @Test func monacoChordsWinInTheCodeEditor() {
        let services = ActionBindingCoverageTests.boundServices()
        let registry = services.registry
        let cmdD = Shortcut("d", modifiers: [.command])
        #expect(registry.keyWinner(cmdD)?.command == "splitRight")
        registry.context = [.codeEditorFocused]
        for shortcut in [cmdD, Shortcut(Shortcut.upArrowKey, modifiers: [.option, .command]), Shortcut("[", modifiers: [.option, .command]),
                         Shortcut("f", modifiers: [.option, .command]), Shortcut("l", modifiers: [.command]), Shortcut("i", modifiers: [.command])] {
            #expect(registry.keyWinner(shortcut) == nil, "\(shortcut.displayString) goes to Monaco")
        }
        #expect(registry.keyWinner(Shortcut("t", modifiers: [.command]))?.command == "newTab.sameKind", "Cmd-T stays the app's")
        #expect(registry.keyWinner(Shortcut("w", modifiers: [.command])) != nil, "Cmd-W stays the app's")
    }
}
