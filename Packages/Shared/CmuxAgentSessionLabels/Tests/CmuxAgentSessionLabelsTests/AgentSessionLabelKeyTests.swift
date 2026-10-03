import Foundation
import Testing

@testable import CmuxAgentSessionLabels

struct AgentSessionLabelKeyTests {
    @Test func rejectsAnEmptyAgentOrSessionID() {
        #expect(throws: AgentSessionLabelError.emptyKeyField(field: "agent")) {
            try AgentSessionLabelKey(agent: " ", sessionID: "s-1")
        }
        #expect(throws: AgentSessionLabelError.emptyKeyField(field: "session id")) {
            try AgentSessionLabelKey(agent: "codex", sessionID: "")
        }
    }

    @Test(arguments: [
        ("codex\u{202E}", "s-1", 0x202E),
        ("codex", "s\u{202E}1", 0x202E),
        ("co\u{200B}dex", "s-1", 0x200B),
        ("codex", "s\u{2028}1", 0x2028),
        ("codex", "s\u{1}1", 0x01)
    ])
    func rejectsTheSameCharactersTheLabelRejects(
        agent: String, sessionID: String, scalar: Int
    ) {
        // Each offending scalar sits inside a word, not at an edge: trimming removes
        // some of them at the edges, which would make the rule look wider than it is.
        // The agent and the session id print on the same row as the label, and the
        // store puts them in its own error text, so a scalar that reverses a row
        // does the same damage from either field.
        #expect(throws: AgentSessionLabelError.disallowedCharacter(
            scalar: Unicode.Scalar(UInt32(scalar))!
        )) {
            try AgentSessionLabelKey(agent: agent, sessionID: sessionID)
        }
    }

    @Test func acceptsASessionIDThatLooksLikeAPath() throws {
        let key = try AgentSessionLabelKey(agent: "codex", sessionID: "../../escaped")
        #expect(key.sessionID == "../../escaped")
    }

    @Test func trimsTheWhitespaceAroundAnIDCopiedOutOfAListing() throws {
        let key = try AgentSessionLabelKey(agent: " codex ", sessionID: "  s-1\n")
        #expect(key.agent == "codex")
        #expect(key.sessionID == "s-1")
    }

    @Test func refusesALineSeparatorAtAnEdgeOfAKeyField() {
        #expect(throws: AgentSessionLabelError.disallowedCharacter(
            scalar: Unicode.Scalar(0x2029)!
        )) {
            try AgentSessionLabelKey(agent: "codex", sessionID: "s-1\u{2029}")
        }
    }

    @Test func rejectsAFieldLongerThanARecordShouldHold() {
        let long = String(repeating: "s", count: AgentSessionLabelKey.maximumFieldLength + 1)
        #expect(throws: AgentSessionLabelError.keyFieldTooLong(
            field: "session id",
            length: AgentSessionLabelKey.maximumFieldLength + 1,
            maximum: AgentSessionLabelKey.maximumFieldLength
        )) {
            try AgentSessionLabelKey(agent: "codex", sessionID: long)
        }
    }

    @Test func ordersKeysByAgentThenSession() throws {
        let first = try AgentSessionLabelKey(agent: "claude", sessionID: "s-2")
        let second = try AgentSessionLabelKey(agent: "codex", sessionID: "s-1")
        let third = try AgentSessionLabelKey(agent: "codex", sessionID: "s-2")
        #expect([third, second, first].sorted() == [first, second, third])
    }
}
