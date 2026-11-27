import CmuxHomeCore
import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// A Chief made outside Home's New Chief (a Chief's `chiefs` tool, `cmux chief new`) has a registry
/// record and no conversation; Home lists conversations, so it opens the person's direct message
/// with that Chief, once, under the same key Home's New Chief uses.
@Suite struct HomeChiefDirectMessagesTests {
    private let me = ConversationParticipant(id: "user_local", kind: .human, displayName: "Me")

    private static let listed: JSONValue = .object(["chiefs": .array([
        .object(["id": .string("agent_mux"), "display_name": .string("Chief")]),
        .object(["id": .string("agent_scout01"), "display_name": .string("Scout")]),
        .object(["id": .string("agent_01M5KF414NPA3JJD601WWAE9SP"), "display_name": .string("Codex Chief")]),
    ])])

    @Test func aChiefWithNoConversationGetsTheDirectMessageHomeListsItBy() async {
        let opens = Opens()
        let dms = HomeChiefDirectMessages(me: me, list: { Self.listed }, open: { request in
            await opens.add(request)
            return "conv_" + (request.participants.last?.id ?? "")
        })
        // The default Chief and Scout already have a conversation; the chiefs tool's Codex Chief does not.
        let opened = await dms.open(missingFrom: ["agent_mux", "agent_scout01"])
        #expect(opened == ["agent_01M5KF414NPA3JJD601WWAE9SP": ConversationID("conv_agent_01M5KF414NPA3JJD601WWAE9SP")])
        let sent = await opens.requests
        #expect(sent.count == 1)
        let dm = try? #require(sent.first)
        #expect(dm?.participants.map(\.id) == ["user_local", "agent_01M5KF414NPA3JJD601WWAE9SP"])
        #expect(dm?.participants.last?.kind == .agent)
        #expect(dm?.participants.last?.agentClass == "mux")
        #expect(dm?.title == "Codex Chief")
        #expect(dm?.idempotencyKey == HomeChiefDirectMessages.key(for: "agent_01M5KF414NPA3JJD601WWAE9SP"))
    }

    @Test func theDefaultChiefIsNeverOpenedHere() async {
        let opens = Opens()
        let dms = HomeChiefDirectMessages(me: me, list: { Self.listed }, open: { request in
            await opens.add(request)
            return "conv"
        })
        _ = await dms.open(missingFrom: [])
        let ids = await opens.requests.compactMap { $0.participants.last?.id }
        #expect(ids == ["agent_scout01", "agent_01M5KF414NPA3JJD601WWAE9SP"])
    }

    @Test func aFailedListOrOpenOpensNothingAndDoesNotThrow() async {
        let unreadable = HomeChiefDirectMessages(me: me, list: { throw DaemonError.notConnected }, open: { _ in "never" })
        #expect(await unreadable.open(missingFrom: []).isEmpty)
        let refused = HomeChiefDirectMessages(me: me, list: { Self.listed }, open: { _ in throw DaemonError.notConnected })
        #expect(await refused.open(missingFrom: []).isEmpty)
    }

    @Test func homesNewChiefOpensItsDirectMessageUnderTheSameKey() async throws {
        let opens = Opens()
        let creator = HomeLocalChiefCreator(me: me, send: { _, _, _ in
            .object(["value": .object(["id": .string("agent_scout01"), "display_name": .string("Scout")])])
        }, open: { request in
            await opens.add(request)
            return "conv_scout"
        })
        _ = try await creator.create(name: "Scout", backend: .codex)
        let dm = try #require(await opens.requests.first)
        // A chief-changed event racing this create opens the same request: the owner replays it.
        let same = HomeChiefDirectMessages.request(me: me, chief: "agent_scout01", name: "Scout")
        #expect(dm.idempotencyKey == same.idempotencyKey)
        #expect(dm.title == same.title)
        #expect(dm.participants == same.participants)
    }
}

/// The `conversation-create` requests the fake owner received.
private actor Opens {
    var requests: [CreateConversationRequest] = []
    func add(_ request: CreateConversationRequest) { requests.append(request) }
}
