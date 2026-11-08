import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// A sender's icon on the phone takes the same tone the Mac gives the same key (agentTones.ts
/// `hashTone`), so a session reads in one color on both, and its family's mark from a harness id.
@MainActor @Suite struct AgentSenderIconTests {
    @Test func toneMatchesTheMacHash() {
        // The Mac's hashTone of the same strings (FNV-1a of the UTF-16 units, modulo five).
        #expect(AgentSenderIcon.hashTone("s-claude-13") == 0)
        #expect(AgentSenderIcon.hashTone("claude-13") == 3)
        #expect(AgentSenderIcon.hashTone("gcp-codex-swarm-08/claude") == 3)
        #expect(AgentSenderIcon.hashTone("lane-a") == 1)
    }

    @Test func tonesAreTheMacsColors() {
        #expect(AgentSenderIcon.toneRGB.count == 5)
        let green = AgentSenderIcon.toneRGB[0]
        #expect(green.0 == 0x3f && green.1 == 0xb9 && green.2 == 0x50)
    }

    @Test func aProfileIdDrawsItsFamilysMark() {
        #expect(AgentSenderIcon.family("claude") == "claude")
        // A profile id the catalog knows ("codex-sol") keeps itself; one it doesn't takes its family.
        #expect(["codex-sol", "codex"].contains(AgentSenderIcon.family("codex-sol")))
        #expect(AgentSenderIcon.family(nil) == nil)
        #expect(AgentSenderIcon.family("") == nil)
    }

    func json(_ string: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8)) }

    /// Two sessions both named "coordinator": the Mac tones each by its session id
    /// (IncomingMessageCard.tsx `agentTone(sender.sessionId ?? message.sessionId ?? message.name)`),
    /// so the phone does too, and two chats with one name read as two.
    @Test func sameNameDifferentSessionsTakeTheirTonesFromTheirIds() throws {
        let first = try json(#"{"kind":"session_message","from":"acp:0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a60","fromName":"coordinator"}"#)
        let second = try json(#"{"kind":"agent_message","from":"acp:0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a63","fromName":"coordinator"}"#)
        let a = try #require(AgentIncoming.parse(text: "Merged.", provenance: first))
        let b = try #require(AgentIncoming.parse(text: "Merged.", provenance: second))
        #expect(a.messages.map(\.sender) == ["coordinator"])
        #expect(b.messages.map(\.sender) == ["coordinator"])
        #expect(a.messages.first?.toneKey == "0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a60")
        #expect(b.messages.first?.toneKey == "0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a63")
        #expect(a.oneSenderKey == "0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a60")
        #expect(AgentSenderIcon.hashTone(a.messages[0].toneKey) != AgentSenderIcon.hashTone(b.messages[0].toneKey))
    }

    /// The tone the Mac gives a session id (agentTones.ts `hashTone`, run on the id with node):
    /// the phone's for the same session's message is the same.
    @Test func toneForASessionIdMatchesTheMacs() throws {
        let provenance = try json(#"{"kind":"subsession_message","from":"acp:0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a60","fromName":"coordinator"}"#)
        let incoming = try #require(AgentIncoming.parse(text: "Done.", provenance: provenance))
        #expect(AgentSenderIcon.hashTone(incoming.messages[0].toneKey) == 3)
        #expect(AgentSenderIcon.hashTone("0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a63") == 0)
        // The name alone would be another tone: the id, not the name, picks it.
        #expect(AgentSenderIcon.hashTone("coordinator") == 1)
    }

    /// An inbox thread's message names its sender's session (`sender.session`, else the thread's
    /// `fromSession`), and its tone comes from that id.
    @Test func inboxMessagesTakeTheirSendersSessionIds() throws {
        let provenance = try json(#"""
        {"kind":"inbox_notice","threads":[
          {"threadId":"from:coordinator","from":["coordinator"],"fromSession":"0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a63",
           "messages":[{"from":"coordinator","sender":{"session":"0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a60"},"text":"one"},
                       {"from":"coordinator","text":"two"}]}]}
        """#)
        let incoming = try #require(AgentIncoming.parse(text: "[inbox] New messages.", provenance: provenance))
        #expect(incoming.messages.map(\.toneKey) == ["0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a60", "0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a63"])
        // Two sessions under one name are two senders: no single sender's icon for the card.
        #expect(incoming.oneSenderKey == nil)
    }

    /// An older payload with no session id keeps the name as its key.
    @Test func noSessionIdFallsBackToTheName() throws {
        let provenance = try json(#"{"kind":"agent_message","from":"fromAgent","fromName":"coordinator"}"#)
        let incoming = try #require(AgentIncoming.parse(text: "Merged.", provenance: provenance))
        #expect(incoming.messages.first?.toneKey == "coordinator")
        #expect(incoming.oneSenderKey == "coordinator")
    }
}
