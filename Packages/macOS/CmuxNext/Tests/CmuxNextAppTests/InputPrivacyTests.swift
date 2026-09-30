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

    @Test func typingKeepsItsClassAndModifiers() throws {
        let journal = Self.journal()
        for event in try Self.typed() { journal.record(event) }
        let keys = journal.entries().compactMap { entry -> InputJournalEntry.Key? in
            if case .key(let key) = entry.kind { key } else { nil }
        }
        #expect(keys.map(\.keyClass) == [.letter, .letter, .letter, .letter, .letter, .letter, .space, .digit, .punctuation, .other])
        #expect(keys.first?.modifiers == .shift)
        #expect(keys.allSatisfy { $0.keyCode == nil && $0.characters == nil })
    }

    /// Shortcuts and non-text keys keep their key code (replay needs it; it
    /// is not text).
    @Test func shortcutsAndNamedKeysKeepTheirKeyCode() throws {
        let journal = Self.journal()
        let events = try [Self.key("k", keyCode: 40, .command), Self.key("c", keyCode: 8, .control), Self.key("\r", keyCode: 36),
                          Self.key(String(UnicodeScalar(NSLeftArrowFunctionKey)!), keyCode: 123, [.function, .numericPad])]
        for event in events { journal.record(event) }
        let keys = journal.entries().compactMap { entry -> InputJournalEntry.Key? in
            if case .key(let key) = entry.kind { key } else { nil }
        }
        #expect(keys.map(\.keyCode) == [40, 8, 36, 123])
        #expect(keys.map(\.keyClass) == [.letter, .letter, .named, .named])
        #expect(keys.allSatisfy { $0.characters == nil })
    }

    /// A desync report is what reaches disk: the typed text is not in it.
    @Test func aDesyncReportCarriesNoTypedText() throws {
        let journal = Self.journal()
        for event in try Self.typed() { journal.record(event) }
        let observation = InputFuzzerSupport.observation()
        let report = DesyncReport(id: "desync-1", sequence: 1, createdAt: Date(timeIntervalSince1970: 0), uptimeNanos: 0, tag: nil,
                                  violations: [], observation: observation, journal: journal.entries(), journalStats: journal.stats)
        let json = try #require(String(data: DesyncReport.encoder.encode(report), encoding: .utf8))
        for fragment in ["\"keyCode\"", "\"characters\"", "Secret", "\"S\"", "å"] {
            #expect(!json.contains(fragment), "\(fragment)")
        }
    }

    /// With the debug opt-in, one session records what was typed.
    @Test func theOptInRecordsCharacters() throws {
        let journal = Self.journal(characters: true)
        journal.record(try Self.key("e", keyCode: 14))
        guard case .key(let key)? = journal.entries().first?.kind else { Issue.record("no key"); return }
        #expect(key.characters == "e")
        #expect(key.keyCode == 14)
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
