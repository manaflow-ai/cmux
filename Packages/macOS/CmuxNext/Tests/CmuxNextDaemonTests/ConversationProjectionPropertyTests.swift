import Foundation
import Testing
@testable import CmuxNextDaemon

/// Seeded property test for the conversation mirror plus intent log against a
/// reference owner (OWNERSHIP-PRINCIPLES.md "Verification"). Each step does one
/// random thing: the user sends (the request is queued in order), the owner
/// serves the next request (commits it, or replays a repeated key without a new
/// revision, or rejects an empty message), another participant sends, events are
/// delivered (sometimes duplicated, sometimes one is lost, which shows as a gap),
/// a reply arrives, or the connection drops (in-flight requests fail; on
/// reconnect the client takes a snapshot and resends its sending entries with
/// the same keys). After every step: no client id is visible twice, every
/// pending send stays visible until the mirror holds it, and with an empty log
/// and nothing in flight the visible transcript equals the owner's.
@Suite struct ConversationProjectionPropertyTests {
    @Test(arguments: 0..<6)
    func mirrorAndIntentLogConverge(chunk: Int) {
        for seed in (chunk * 200)..<((chunk + 1) * 200) {
            var world = ConversationWorld(seed: UInt64(seed))
            for _ in 0..<120 {
                world.step()
                world.checkInvariants()
            }
            world.drain()
            #expect(world.client.log.isEmpty || world.client.log.entries.allSatisfy { if case .failed = $0.state { true } else { false } },
                    "seed \(seed): log did not drain")
            #expect(world.visibleConfirmedIDs() == world.owner.messages.map(\.clientMsgID), "seed \(seed): did not converge")
        }
    }
}

/// The owner: commits sends once per idempotency key, in arrival order.
struct ReferenceOwner {
    var rev: UInt64 = 0
    var messages: [ConversationMessage] = []
    var ledger: [String: UInt64] = [:]

    struct Rejected: Error { var reason: String }

    mutating func send(clientMsgID: String, author: String, empty: Bool) -> Result<(rev: UInt64, change: ConversationChange?), Rejected> {
        if let rev = ledger[clientMsgID] { return .success((rev, nil)) }
        guard !empty else { return .failure(Rejected(reason: "invalid_parts")) }
        rev += 1
        let message = ConversationMessage(id: "msg_\(rev)", conversation: "c", seq: UInt64(messages.count + 1), clientMsgID: clientMsgID,
                                          author: author, parts: [.text(clientMsgID, runs: [])], createdAt: "t")
        messages.append(message)
        ledger[clientMsgID] = rev
        return .success((rev, .message(message)))
    }

    func snapshot() -> ConversationSnapshot {
        ConversationSnapshot(conversation: ConversationSummary(id: "c", title: "t", participants: [], lastSeq: UInt64(messages.count),
                                                               rev: rev, createdAt: "t", updatedAt: "t"),
                             messages: Array(messages.suffix(400)))
    }
}

struct ReferenceClient {
    var mirror: ConversationMirror
    var log = ConversationIntentLog()
}
