import AppKit
import CmuxMobileTerminalKit
import Testing
@testable import CmuxHiveUI

@Suite struct HiveTerminalKeyMappingTests {
    @Test func arrowKeysMapToSpecialKeys() {
        let action = HiveTerminalKeyMapping.action(
            keyCode: 126,
            characters: nil,
            charactersIgnoringModifiers: nil,
            modifiers: []
        )
        #expect(action == .special(.upArrow, []))
    }

    @Test func modifiersRideAlongOnSpecialKeys() {
        let action = HiveTerminalKeyMapping.action(
            keyCode: 123,
            characters: nil,
            charactersIgnoringModifiers: nil,
            modifiers: [.option]
        )
        #expect(action == .special(.leftArrow, [.alternate]))
        let shiftTab = HiveTerminalKeyMapping.action(
            keyCode: 48,
            characters: nil,
            charactersIgnoringModifiers: nil,
            modifiers: [.shift]
        )
        #expect(shiftTab == .special(.tab, [.shift]))
    }

    @Test func returnAndBackspaceMapToBytes() {
        #expect(HiveTerminalKeyMapping.action(
            keyCode: 36, characters: "\r", charactersIgnoringModifiers: "\r", modifiers: []
        ) == .text("\r"))
        #expect(HiveTerminalKeyMapping.action(
            keyCode: 51, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", modifiers: []
        ) == .text("\u{7F}"))
    }

    @Test func controlCombinationsUseBaseCharacter() {
        let action = HiveTerminalKeyMapping.action(
            keyCode: 8,
            characters: "\u{03}",
            charactersIgnoringModifiers: "c",
            modifiers: [.control]
        )
        #expect(action == .control("c"))
        // The shared encoder turns it into the control byte.
        #expect(TerminalKeyEncoder.controlCharacter(for: "c") == Data([0x03]))
    }

    @Test func plainTypingPassesThroughAndCommandChordsDoNot() {
        #expect(HiveTerminalKeyMapping.action(
            keyCode: 0, characters: "a", charactersIgnoringModifiers: "a", modifiers: []
        ) == .text("a"))
        #expect(HiveTerminalKeyMapping.action(
            keyCode: 0, characters: "a", charactersIgnoringModifiers: "a", modifiers: [.command]
        ) == nil)
    }
}
