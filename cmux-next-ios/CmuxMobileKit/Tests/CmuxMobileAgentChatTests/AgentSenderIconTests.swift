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

    /// A digest as acpmux records it (hub/digest.rs `digest_provenance`): each part's `from` is its
    /// sender's name, and the sending chat's address is in the part's own `provenance.from`.
    @Test func digestPartsTakeTheirSessionIdsFromTheirOwnProvenance() throws {
        let provenance = try json(#"""
        {"kind":"agent_digest","messages":[
          {"promptId":"p-1","from":"coordinator",
           "provenance":{"kind":"agent_message","from":"acp:0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a60","fromName":"coordinator","msgId":"m-1"}},
          {"promptId":"p-2","from":"coordinator",
           "provenance":{"kind":"session_message","from":"0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a63","fromName":"coordinator"}},
          {"promptId":"p-3","from":"build-box/lane-3","provenance":{"kind":"agent_message","from":"fromAgent","fromName":"build-box/lane-3"}}]}
        """#)
        let text = """
        3 messages from other agents arrived while you were busy. Each follows as it was sent, oldest first.

        [agent message 1 of 3] from coordinator
        landing #9

        [agent message 2 of 3] from coordinator
        landed #9

        [agent message 3 of 3] from build-box/lane-3
        review passed
        """
        let incoming = try #require(AgentIncoming.parse(text: text, provenance: provenance))
        #expect(incoming.messages.map(\.sender) == ["coordinator", "coordinator", "build-box/lane-3"])
        #expect(incoming.messages.map(\.toneKey)
            == ["0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a60", "0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a63", "build-box/lane-3"])
    }

    /// Two sessions whose ids hash to the same tone: the Mac's `agentTones` (agentTones.ts, run with
    /// bun on these ids) gives the first its hash's tone and moves the second to the next free one.
    @Test func idsThatHashAlikeTakeTheMacsAssignedTones() {
        let a = "0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a02", b = "0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a09"
        let c = "0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a0a", d = "0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a63"
        #expect([a, b, c].map(AgentSenderIcon.hashTone) == [3, 3, 3])
        var two = AgentTones()
        #expect(two.assign([.init(id: a, startedAt: 1), .init(id: b, startedAt: 2)]) == [a: 3, b: 4])
        var four = AgentTones()
        let all = four.assign([.init(id: d, startedAt: 4), .init(id: c, startedAt: 3), .init(id: b, startedAt: 2), .init(id: a, startedAt: 1)])
        #expect(all == [a: 3, b: 4, c: 0, d: 1])
        // An agent keeps the tone it has when a later one joins.
        #expect(two.assign([.init(id: a, startedAt: 1), .init(id: b, startedAt: 2), .init(id: c, startedAt: 3)]) == [a: 3, b: 4, c: 0])
    }

    /// In a chat, the senders' cards take those assigned tones: two sessions whose ids hash alike
    /// draw in two tones, as on the Mac.
    @MainActor @Test func aChatsSendersWhoseIdsHashAlikeDrawInTwoTones() throws {
        let store = AgentChatStore(source: AgentIncomingTests.Recorder())
        let a = "0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a02", b = "0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a09"
        let start = Date(timeIntervalSince1970: 1_000)
        for (index, id) in [a, b].enumerated() {
            store.apply(.userMessage(text: "done", promptId: "p-\(index)", turnId: "t-\(index)", attachments: [],
                                     at: start.addingTimeInterval(Double(index))))
            let provenance = try json(#"{"kind":"agent_message","from":"acp:"# + id + #"","fromName":"lane"}"#)
            store.apply(.promptFrom(turnId: "t-\(index)", incoming: try #require(AgentIncoming.parse(text: "done", provenance: provenance))))
        }
        let rows = ChatTranscriptBuilder(diffs: ChatDiffCache()).build(turns: store.turns, pendingPermission: nil, askOpen: false,
                                                                         permissionBarHidden: false)
        let tones = rows.flatMap(\.rows).compactMap { row -> Int? in
            guard case .incoming(let incoming, _, _) = row.kind else { return nil }
            return incoming.messages.first?.tone
        }
        #expect(tones == [3, 4])
    }

    /// Only the kinds the Mac reads a session from carry one (incomingMessage.ts): a session kind's
    /// `from` and an `agent_message`'s `acp:` address. A kind this build does not know, an unverified
    /// send and a tool's notice name no session even from an `acp:` address, so their tone is the name's.
    @Test func onlyTheMacsKindsCarryASessionId() throws {
        let unknown = try json(#"{"kind":"future_kind","from":"acp:0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a60","fromName":"lane-z"}"#)
        let card = try #require(AgentIncoming.parse(text: "hello", provenance: unknown))
        #expect(card.messages.first?.senderID == nil)
        #expect(card.messages.first?.toneKey == "lane-z")
        let unverified = try json(#"{"kind":"unverified","from":"acp:0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a60","to":"s-1","verified":false}"#)
        #expect(try #require(AgentIncoming.parse(text: "[lane-q] hello", provenance: unverified)).messages.first?.senderID == nil)
        let notice = try json(#"{"kind":"notice","from":"acp:0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a60","fromName":"land-ci","notice":{"sender":"land-ci","title":"CI red"}}"#)
        #expect(try #require(AgentIncoming.parse(text: "CI red", provenance: notice)).messages.first?.senderID == nil)
        // A digest part of an unknown kind names no session either.
        let digest = try json(#"""
        {"kind":"agent_digest","messages":[
          {"from":"lane-z","provenance":{"kind":"future_kind","from":"acp:0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a60","fromName":"lane-z"}},
          {"from":"coordinator","provenance":{"kind":"agent_message","from":"acp:0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a63","fromName":"coordinator"}}]}
        """#)
        let text = """
        2 messages from other agents arrived while you were busy. Each follows as it was sent, oldest first.

        [agent message 1 of 2] from lane-z
        one

        [agent message 2 of 2] from coordinator
        two
        """
        #expect(try #require(AgentIncoming.parse(text: text, provenance: digest)).messages.map(\.senderID)
            == [nil, "0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a63"])
    }
}
