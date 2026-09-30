import AppKit
@testable import CmuxNextApp
import Foundation
import Testing

/// Typed text never reaches the input journal or a desync report on disk
/// (plans/cmux-next/input-spec.md section 3). Plain typing is journaled as a
/// key class; a key code only for shortcuts and non-text keys.
struct InputPrivacyTests {
    static func key(_ characters: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                      context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: keyCode))
    }

    /// "Secret 1!" typed into a terminal or the omnibar.
    static func typed() throws -> [NSEvent] {
        try [key("S", keyCode: 1, .shift), key("e", keyCode: 14), key("c", keyCode: 8), key("r", keyCode: 15),
             key("e", keyCode: 14), key("t", keyCode: 17), key(" ", keyCode: 49), key("1", keyCode: 18),
             key("!", keyCode: 18, .shift), key("å", keyCode: 0, .option)]
    }

    static func journal(characters: Bool = false) -> InputJournal {
        let journal = InputJournal(capacity: 64)
        journal.configure(InputJournalPolicy(enabled: true, recordsCharacters: characters))
        return journal
    }

    @Test func typingLeavesNoKeyCodeOrCharacterInTheJournal() throws {
        let journal = Self.journal()
        for event in try Self.typed() { journal.record(event) }
        let json = try #require(String(data: DesyncReport.encoder.encode(journal.entries()), encoding: .utf8))
        #expect(!json.contains("\"keyCode\""), "\(json)")
        #expect(!json.contains("\"characters\""), "\(json)")
    }

    /// The characters opt-in is for debug builds only, never a tagged
    /// release build.
    @Test func charactersOptInNeedsADebugBuild() {
        let policy = InputJournalPolicy.resolve(isDebugBuild: false, tag: "tag",
                                                environment: ["CMUX_NEXT_INPUT_JOURNAL_CHARACTERS": "1"])
        #expect(policy.enabled)
        #expect(!policy.recordsCharacters)
    }
}
