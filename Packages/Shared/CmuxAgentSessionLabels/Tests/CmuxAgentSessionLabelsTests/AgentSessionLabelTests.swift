import Foundation
import Testing

@testable import CmuxAgentSessionLabels

struct AgentSessionLabelTests {
    private let now = Date(timeIntervalSince1970: 1_790_536_000)

    @Test func trimsTheEndsAndKeepsTheMiddle() throws {
        let label = try AgentSessionLabel(text: "  rename the  audit rows \n", updatedAt: now)
        #expect(label.text == "rename the  audit rows")
    }

    @Test func refusesALineSeparatorAtAnEdgeRatherThanTrimmingIt() {
        // A line separator is whitespace that this type rejects, so trimming the
        // whole whitespace set would accept text a label may not hold, in a
        // reader that treats U+2028 as a line break, and say nothing about it.
        #expect(throws: AgentSessionLabelError.disallowedCharacter(
            scalar: Unicode.Scalar(0x2028)!
        )) {
            try AgentSessionLabel(text: "\u{2028}audit rows", updatedAt: now)
        }
        #expect(throws: AgentSessionLabelError.disallowedCharacter(
            scalar: Unicode.Scalar(0x0085)!
        )) {
            try AgentSessionLabel(text: "audit rows\u{0085}", updatedAt: now)
        }
    }

    @Test func rejectsAnEmptyLabel() {
        #expect(throws: AgentSessionLabelError.emptyLabel) {
            try AgentSessionLabel(text: "   \t\n  ", updatedAt: now)
        }
    }

    @Test func acceptsTheLongestLabelAndRejectsOneCharacterMore() throws {
        let longest = String(repeating: "a", count: AgentSessionLabel.maximumLength)
        let label = try AgentSessionLabel(text: longest, updatedAt: now)
        #expect(label.text.count == AgentSessionLabel.maximumLength)
        #expect(throws: AgentSessionLabelError.labelTooLong(
            length: AgentSessionLabel.maximumLength + 1,
            maximum: AgentSessionLabel.maximumLength
        )) {
            try AgentSessionLabel(text: longest + "a", updatedAt: now)
        }
    }

    @Test func countsCharactersRatherThanBytes() throws {
        // 120 characters of three bytes each: a byte limit would reject this.
        let text = String(repeating: "変", count: AgentSessionLabel.maximumLength)
        let label = try AgentSessionLabel(text: text, updatedAt: now)
        #expect(label.text.count == AgentSessionLabel.maximumLength)
        #expect(label.text.utf8.count == AgentSessionLabel.maximumLength * 3)
    }

    @Test(arguments: [
        ("two\nlines", 0x0A),
        ("a\ttab", 0x09),
        ("a\u{0}nul", 0x00),
        ("a\u{200B}space", 0x200B),
        ("a\u{202E}reversed", 0x202E),
        ("first\u{2028}second", 0x2028),
        ("first\u{2029}second", 0x2029),
        ("a\u{2066}isolated", 0x2066),
    ])
    func rejectsCharactersAListingCannotShowHonestly(text: String, scalar: Int) {
        // The scalar is asserted, not just the throw: trimming alone would reject
        // several of these as empty, which is the right answer for the wrong
        // reason and would not catch a rule that stopped looking inside the text.
        #expect(throws: AgentSessionLabelError.disallowedCharacter(
            scalar: Unicode.Scalar(UInt32(scalar))!
        )) {
            try AgentSessionLabel(text: text, updatedAt: now)
        }
    }

    @Test(arguments: [
        "👩‍💻 pairing",
        "🏴󠁧󠁢󠁳󠁣󠁴󠁿 deploy",
        "ספ\u{200E}main.swift\u{200E} בדיקה",
        "e\u{301}migre\u{301}",
        "🇯🇵 tokyo box"
    ])
    func acceptsNamesPeopleActuallyWrite(text: String) throws {
        // Every one of these carries an invisible or combining scalar. A rule that
        // refused all of them would refuse a flag, a Hebrew label embedding a file
        // name, and a joined emoji.
        let label = try AgentSessionLabel(text: text, updatedAt: now)
        #expect(label.text == text)
    }

    @Test func rejectsALabelThatIsTooManyBytesToStore() {
        // One character carrying 400 combining marks: the character cap cannot see
        // it, and every label shares one document.
        let text = "a" + String(repeating: "\u{301}", count: 400)
        #expect(text.count == 1)
        #expect(throws: AgentSessionLabelError.labelTooManyBytes(
            bytes: text.utf8.count, maximum: AgentSessionLabel.maximumByteCount
        )) {
            try AgentSessionLabel(text: text, updatedAt: now)
        }
    }

    @Test func keepsTheTimeItWasGiven() throws {
        let label = try AgentSessionLabel(text: "audit", updatedAt: now)
        #expect(label.updatedAt == now)
    }

    @Test func dropsTheFractionOfASecondTheFileCannotHold() throws {
        // The store writes ISO 8601 seconds. Keeping the fraction here would make
        // a caller that compares what it wrote against what it read see a change
        // that never happened.
        let label = try AgentSessionLabel(
            text: "audit", updatedAt: now.addingTimeInterval(0.75)
        )
        #expect(label.updatedAt == now)
    }
}
