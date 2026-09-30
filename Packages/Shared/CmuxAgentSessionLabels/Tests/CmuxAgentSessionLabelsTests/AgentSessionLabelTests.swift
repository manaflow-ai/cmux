import Foundation
import Testing

@testable import CmuxAgentSessionLabels

struct AgentSessionLabelTests {
    private let now = Date(timeIntervalSince1970: 1_790_536_000)

    @Test func trimsTheEndsAndKeepsTheMiddle() throws {
        let label = try AgentSessionLabel(text: "  rename the  audit rows \n", updatedAt: now)
        #expect(label.text == "rename the  audit rows")
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
        "two\nlines", "a\ttab", "a\u{0}nul", "a\u{200B}space", "a\u{202E}reversed",
    ])
    func rejectsCharactersAListingCannotShowHonestly(text: String) {
        #expect(throws: AgentSessionLabelError.self) {
            try AgentSessionLabel(text: text, updatedAt: now)
        }
    }

    @Test func acceptsAJoinedEmoji() throws {
        let label = try AgentSessionLabel(text: "👩‍💻 pairing", updatedAt: now)
        #expect(label.text == "👩‍💻 pairing")
    }

    @Test func keepsTheTimeItWasGiven() throws {
        let label = try AgentSessionLabel(text: "audit", updatedAt: now)
        #expect(label.updatedAt == now)
    }

    @Test func rejectsAnEmptyAgentOrSessionID() {
        #expect(throws: AgentSessionLabelError.emptyKeyField(field: "agent")) {
            try AgentSessionLabelKey(agent: " ", sessionID: "s-1")
        }
        #expect(throws: AgentSessionLabelError.emptyKeyField(field: "session id")) {
            try AgentSessionLabelKey(agent: "codex", sessionID: "")
        }
    }

    @Test func ordersKeysByAgentThenSession() throws {
        let first = try AgentSessionLabelKey(agent: "claude", sessionID: "s-2")
        let second = try AgentSessionLabelKey(agent: "codex", sessionID: "s-1")
        let third = try AgentSessionLabelKey(agent: "codex", sessionID: "s-2")
        #expect([third, second, first].sorted() == [first, second, third])
    }
}
