import AppKit
@testable import CmuxNextBrowser
import Testing

/// Cmd-V reaching a Chromium page is the paste a cmux page records first (`CEFTab.pagePasted`,
/// `CEFRuntime.routeKey`); no other chord is.
@MainActor
struct CEFPasteKeyTests {
    private func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 9))
    }

    @Test func onlyCommandVIsAPaste() throws {
        #expect(CEFRuntime.isPaste(try key("v", .command)))
        #expect(CEFRuntime.isPaste(try key("V", [.command, .capsLock])), "Caps Lock on is still Paste")
        #expect(CEFRuntime.isPaste(try key("v", [.command, .shift])) == false, "Paste and Match Style")
        #expect(CEFRuntime.isPaste(try key("v", [.command, .option])) == false)
        #expect(CEFRuntime.isPaste(try key("v", [])) == false)
        #expect(CEFRuntime.isPaste(try key("c", .command)) == false)
    }
}
