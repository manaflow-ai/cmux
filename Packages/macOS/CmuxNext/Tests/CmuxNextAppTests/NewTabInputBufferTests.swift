import AppKit
import Testing
@testable import CmuxNextApp

/// Cmd-T owns printable keys from the action until the New Tab field is ready.
/// The same sequence must survive both a parked spare and a cold page.
@MainActor @Suite struct NewTabInputBufferTests {
    private func event(_ character: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: character, charactersIgnoringModifiers: character,
                         isARepeat: false, keyCode: 4)!
    }

    @Test func warmAndColdOpeningsReplayTheOriginalKeyEventsInOrder() {
        var delivered: [String] = []
        let buffer = NewTabInputBuffer(focusField: { true }, deliver: { delivered.append($0.characters ?? "") })
        for character in "hello" { #expect(buffer.capture(event(String(character)))) }
        buffer.acknowledge(buffer.token)
        #expect(buffer.drain())
        #expect(delivered == ["h", "e", "l", "l", "o"])
    }
}
