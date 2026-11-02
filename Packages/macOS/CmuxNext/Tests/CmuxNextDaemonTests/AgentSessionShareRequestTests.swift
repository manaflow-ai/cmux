import Foundation
import Testing
@testable import CmuxNextDaemon

/// The link share verbs as the daemon reads them (cmux-tui-core agent_session_shares.rs, whose
/// params refuse unknown fields): snake_case fields, absent options left out.
struct AgentSessionShareRequestTests {
    private func fields(_ request: some DaemonRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(request, id: 1))
    }

    @Test func createCarriesTheOwnerTokenOnlyWhenThereIsOne() throws {
        let full = AgentSessionShareCreateRequest(surface: 3, session: "acp-1", createId: "req-1", ttlSecs: 3600, uses: 2, ownerToken: "jwt")
        #expect(try fields(full) == .object([
            "id": .number(1), "cmd": .string("agent-session-share-create"), "surface": .number(3),
            "session": .string("acp-1"), "create_id": .string("req-1"), "ttl_secs": .number(3600), "uses": .number(2),
            "owner_token": .string("jwt"),
        ]))
        #expect(try fields(AgentSessionShareCreateRequest(surface: 3)) == .object([
            "id": .number(1), "cmd": .string("agent-session-share-create"), "surface": .number(3),
        ]))
    }

    @Test func listRevokeAndKickNameWhatTheyAct() throws {
        #expect(try fields(AgentSessionShareListRequest()) == .object(["id": .number(1), "cmd": .string("agent-session-share-list")]))
        #expect(try fields(AgentSessionShareRevokeRequest(shareId: "s1")) == .object([
            "id": .number(1), "cmd": .string("agent-session-share-revoke"), "share_id": .string("s1"),
        ]))
        #expect(try fields(AgentSessionShareKickRequest(shareId: "s1", guestId: "g2")) == .object([
            "id": .number(1), "cmd": .string("agent-session-share-kick"), "share_id": .string("s1"), "guest_id": .string("g2"),
        ]))
    }

    @Test func createAndListAnswersDecode() throws {
        let created = #"{"ok":true,"data":{"share_id":"s1","secret":"k","url":"https://room/g/s1#k","expires_at":1700000000000,"session":"acp-1","surface":3,"uses_left":1,"room":"https://room"}}"#
        #expect(try WireCoding.decodeResponse(AgentSessionShareCreated.self, from: Data(created.utf8))
            == AgentSessionShareCreated(shareId: "s1", url: "https://room/g/s1#k", expiresAt: 1_700_000_000_000, session: "acp-1", surface: 3, usesLeft: 1))
        let listed = #"{"ok":true,"data":{"shares":[{"share_id":"s1","session":"acp-1","surface":3,"created_at":1,"expires_at":2,"expires_in_secs":86399,"uses_left":0,"state":"active","url":null,"create_id":"req-1","room":null,"guests":[{"guest_id":"g2","name":"Theo","joined_at":5,"state":"active"}]}]}}"#
        let list = try WireCoding.decodeResponse(AgentSessionShareList.self, from: Data(listed.utf8))
        #expect(list.shares.first?.isLive == true)
        #expect(list.shares.first?.createId == "req-1")
        #expect(list.shares.first?.guests == [AgentSessionShareGuest(guestId: "g2", name: "Theo", joinedAt: 5, state: "active")])
    }
}
