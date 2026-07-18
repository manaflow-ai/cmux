import AppKit
@testable import CmuxTerminalFrontend
import Testing

@MainActor
@Suite struct TerminalFrontendInputTranslatorTests {
    private let translator = TerminalFrontendInputTranslator()

    @Test func translatesPhysicalKeyTextActionAndConsumedModifiers() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift, .option],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: "Å",
            charactersIgnoringModifiers: "a",
            isARepeat: true,
            keyCode: 0
        ))

        let translated = translator.keyEvent(
            from: event,
            interpretedText: "Å",
            consumedModifierFlags: [.shift, .option, .control],
            unshiftedCodepoint: 0x61
        )

        #expect(translated.key == TerminalW3CKey.keyA.rawValue)
        #expect(translated.modifiers == [.shift, .option])
        #expect(translated.consumedModifiers == [.shift, .option])
        #expect(translated.text == "Å")
        #expect(translated.unshiftedCodepoint == 0x61)
        #expect(translated.action == .repeat)
    }

    @Test func preservesRightModifierIdentityFromAppKitDeviceFlags() throws {
        let rawFlags = NSEvent.ModifierFlags.shift.rawValue
            | UInt(NX_DEVICERSHIFTKEYMASK)
        let event = try #require(NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: rawFlags),
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 60
        ))

        let translated = translator.keyEvent(
            from: event,
            interpretedText: nil,
            consumedModifierFlags: [.shift]
        )

        #expect(translated.key == TerminalW3CKey.shiftRight.rawValue)
        #expect(translated.modifiers == [.shift, .rightShift])
        #expect(translated.consumedModifiers == [.shift])
        #expect(translated.action == .press)
    }

    @Test func derivesReleaseAndRejectsPrivateUseTextFallback() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [.function],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: String(UnicodeScalar(0xF704)!),
            charactersIgnoringModifiers: String(UnicodeScalar(0xF704)!),
            isARepeat: false,
            keyCode: 122
        ))

        let translated = translator.keyEvent(
            from: event,
            interpretedText: nil
        )

        #expect(translated.key == TerminalW3CKey.f1.rawValue)
        #expect(translated.text == nil)
        #expect(translated.unshiftedCodepoint == 0)
        #expect(translated.action == .release)
    }

    @Test func flagsChangedUsesTheChangedModifiersDeviceSide() throws {
        let rawFlags = NSEvent.ModifierFlags.shift.rawValue
            | UInt(NX_DEVICELSHIFTKEYMASK)
        let event = try #require(NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: rawFlags),
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 60
        ))

        let translated = translator.keyEvent(from: event, interpretedText: nil)

        #expect(translated.key == TerminalW3CKey.shiftRight.rawValue)
        #expect(translated.modifiers == [.shift])
        #expect(translated.action == .release)
    }

    @Test func splitsCommittedControlCharactersIntoCanonicalOrderedInputs() {
        let inputs = translator.committedInputs(
            from: "a\r\nb\t\u{1B}c",
            preserveLiteralEscape: false
        )

        #expect(inputs == [
            .text(TerminalExternalTextInput(text: "a", kind: .committed)),
            .namedKey("enter"),
            .text(TerminalExternalTextInput(text: "b", kind: .committed)),
            .namedKey("tab"),
            .namedKey("escape"),
            .text(TerminalExternalTextInput(text: "c", kind: .committed)),
        ])
    }

    @Test func preservesLiteralEscapeWhenTheCallerRequestsByteExactText() {
        let inputs = translator.committedInputs(
            from: NSAttributedString(string: "a\u{1B}b"),
            preserveLiteralEscape: true
        )

        #expect(inputs == [
            .text(TerminalExternalTextInput(text: "a\u{1B}b", kind: .committed)),
        ])
    }

    @Test func clampsPreeditSelectionInUTF16Coordinates() {
        #expect(translator.preedit(from: "a😀", selectedRange: NSRange(
            location: 2,
            length: 10
        )) == TerminalExternalPreedit(
            text: "a😀",
            selectionStartUTF16: 2,
            selectionLengthUTF16: 1,
            caretUTF16: 3
        ))

        #expect(translator.preedit(from: "a😀", selectedRange: NSRange(
            location: NSNotFound,
            length: 0
        )) == .collapsedAtEnd("a😀"))
        #expect(translator.preedit(from: "", selectedRange: .init()) == nil)
    }
}
