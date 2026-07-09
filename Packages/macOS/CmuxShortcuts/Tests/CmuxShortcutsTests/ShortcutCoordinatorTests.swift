import AppKit
import Testing
@testable import CmuxShortcuts

@MainActor
@Suite("ShortcutCoordinator decode")
struct ShortcutCoordinatorTests {
    private func makeCoordinator(
        layout: @escaping (UInt16, NSEvent.ModifierFlags) -> String? = { _, _ in nil }
    ) -> ShortcutCoordinator {
        ShortcutCoordinator(layoutCharacterProvider: layout)
    }

    @Test("layoutCharacter forwards to the injected provider")
    func layoutCharacterForwards() {
        let coordinator = makeCoordinator { keyCode, _ in keyCode == 18 ? "1" : nil }
        #expect(coordinator.layoutCharacter(forKeyCode: 18, modifierFlags: []) == "1")
        #expect(coordinator.layoutCharacter(forKeyCode: 19, modifierFlags: []) == nil)
    }

    @Test("normalize maps +/_ to =/- only inside the shift gate (faithful to the relocated AppDelegate path)")
    func normalizePlusUnderscoreShiftGated() {
        let coordinator = makeCoordinator()
        // The relocated AppDelegate decode keeps +/_ inside the shift-gated table,
        // so they pass through unchanged when the gate is off.
        #expect(coordinator.normalizedShortcutEventCharacter("+", applyShiftSymbolNormalization: false, eventKeyCode: 0) == "+")
        #expect(coordinator.normalizedShortcutEventCharacter("_", applyShiftSymbolNormalization: false, eventKeyCode: 0) == "_")
        #expect(coordinator.normalizedShortcutEventCharacter("+", applyShiftSymbolNormalization: true, eventKeyCode: 0) == "=")
        #expect(coordinator.normalizedShortcutEventCharacter("_", applyShiftSymbolNormalization: true, eventKeyCode: 0) == "-")
    }

    @Test("normalize lowercases and passes through when shift gate is off")
    func normalizeLowercasesWhenGateOff() {
        let coordinator = makeCoordinator()
        #expect(coordinator.normalizedShortcutEventCharacter("A", applyShiftSymbolNormalization: false, eventKeyCode: 0) == "a")
        #expect(coordinator.normalizedShortcutEventCharacter("!", applyShiftSymbolNormalization: false, eventKeyCode: 18) == "!")
    }

    @Test("normalize maps shift symbols to base keys with keyCode guard")
    func normalizeShiftSymbols() {
        let coordinator = makeCoordinator()
        #expect(coordinator.normalizedShortcutEventCharacter("!", applyShiftSymbolNormalization: true, eventKeyCode: 18) == "1")
        // Wrong keyCode for "!" falls back to the lowered glyph, not "1".
        #expect(coordinator.normalizedShortcutEventCharacter("!", applyShiftSymbolNormalization: true, eventKeyCode: 99) == "!")
        #expect(coordinator.normalizedShortcutEventCharacter("{", applyShiftSymbolNormalization: true, eventKeyCode: 0) == "[")
        #expect(coordinator.normalizedShortcutEventCharacter("?", applyShiftSymbolNormalization: true, eventKeyCode: 0) == "/")
    }

    @Test("numbered digit resolves a plain ASCII digit character")
    func numberedDigitPlainASCII() {
        let coordinator = makeCoordinator()
        let digit = coordinator.numberedShortcutDigit(
            eventKeyCode: 18,
            eventCharactersIgnoringModifiers: "1",
            eventModifierFlags: [.command],
            requireModifierFlags: [.command]
        )
        #expect(digit == 1)
    }

    @Test("numbered digit rejects when modifier flags do not match the bound stroke")
    func numberedDigitRejectsModifierMismatch() {
        let coordinator = makeCoordinator()
        let digit = coordinator.numberedShortcutDigit(
            eventKeyCode: 18,
            eventCharactersIgnoringModifiers: "1",
            eventModifierFlags: [.command, .shift],
            requireModifierFlags: [.command]
        )
        #expect(digit == nil)
    }

    @Test("numbered digit falls back to the layout provider for non-ASCII input")
    func numberedDigitLayoutFallback() {
        // Korean 두벌식: charactersIgnoringModifiers is non-ASCII, so decode must
        // fall back to the layout provider, which resolves keyCode 18 to "1".
        let coordinator = makeCoordinator { keyCode, _ in keyCode == 18 ? "1" : nil }
        let digit = coordinator.numberedShortcutDigit(
            eventKeyCode: 18,
            eventCharactersIgnoringModifiers: "ㅂ",
            eventModifierFlags: [.command],
            requireModifierFlags: [.command]
        )
        #expect(digit == 1)
    }

    @Test("numbered digit returns the keyCode digit when no character path resolves")
    func numberedDigitKeyCodeFallback() {
        let coordinator = makeCoordinator()
        let digit = coordinator.numberedShortcutDigit(
            eventKeyCode: 19,
            eventCharactersIgnoringModifiers: nil,
            eventModifierFlags: [.command],
            requireModifierFlags: [.command]
        )
        #expect(digit == 2)
    }

    @Test("numbered digit returns nil for a non-number key")
    func numberedDigitNonNumberKey() {
        let coordinator = makeCoordinator()
        let digit = coordinator.numberedShortcutDigit(
            eventKeyCode: 0, // kVK_ANSI_A
            eventCharactersIgnoringModifiers: "a",
            eventModifierFlags: [.command],
            requireModifierFlags: [.command]
        )
        #expect(digit == nil)
    }
}
