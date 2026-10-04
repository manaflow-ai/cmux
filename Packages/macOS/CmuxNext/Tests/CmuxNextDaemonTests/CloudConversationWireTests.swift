import Foundation
import Testing
@testable import CmuxNextDaemon

/// Wire shapes of `cloud-conversations-v1` (plans/cmux-next/home-cloud-proxy.md
/// sections 3 to 6): op requests, the cloud events, and a reject's stable
/// `reason` and `retryable` flag on the raw protocol.
@Suite(.timeLimit(.minutes(1))) struct CloudConversationWireTests {
    private func object<R: DaemonRequest>(_ request: R) throws -> [String: JSONValue] {
        let data = try WireCoding.encodeRequest(request, id: 1)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DaemonError.malformedResponse("not an object")
        }
        return object
    }

    @Test func dmOpenNamesNoConversationAndSendsTheAddressPeer() throws {
        let request = CloudConversationOpRequest(conversation: nil, idempotencyKey: "cmk_1", op: .dmOpen(peer: .address(.email("a@b.co"))))
        let object = try object(request)
        #expect(object["cmd"] == .string("cloud-conversation-op"))
        #expect(object["conversation"] == nil)
        #expect(object["idempotency_key"] == .string("cmk_1"))
        #expect(object["origin"] == .string("user"))
        #expect(object["op"] == .object(["kind": .string("dm.open"), "peer": .object(["email": .string("a@b.co")])]))
    }

    @Test func sendAndInviteKeepTheOwnersFieldNames() throws {
        let send = try object(CloudConversationOpRequest(
            conversation: "conv_01J0000000000000000000000A", idempotencyKey: "cmk_2",
            op: .send(clientMsgID: "cmk_2", parts: [.text("hi", runs: [ConversationTextRun(start: 0, length: 2, mention: "user_b")])],
                      replyTo: nil)))
        #expect(send["conversation"] == .string("conv_01J0000000000000000000000A"))
        guard case .object(let op) = send["op"] else { Issue.record("op"); return }
        #expect(op["kind"] == .string("message.send"))
        #expect(op["client_msg_id"] == .string("cmk_2"))

        let invite = try object(CloudConversationOpRequest(
            conversation: "conv_01J0000000000000000000000A", idempotencyKey: "k",
            op: .createInvite(address: .phone("+14155550100"), displayName: "+1 *** *** 0100", locale: nil)))
        #expect(invite["op"] == .object(["kind": .string("invite.create"), "address": .object(["phone": .string("+14155550100")]),
                                         "display_name": .string("+1 *** *** 0100")]))

        let create = try object(CloudConversationOpRequest(
            conversation: nil, idempotencyKey: "k2",
            op: .create(title: nil, participants: [ConversationParticipant(id: "user_a", kind: .human, displayName: "A")])))
        #expect(create["op"] == .object(["kind": .string("conversation.create"),
                                         "participants": .array([.object(["id": .string("user_a"), "kind": .string("human"),
                                                                          "display_name": .string("A")])])]))
    }

    @Test func readsClampToTheOwnersLimitsAndTheLeaseNeverPrintsItsToken() throws {
        #expect(try object(CloudConversationSnapshotRequest(conversation: "c", tail: 60))["tail"] == .number(50))
        #expect(try object(CloudConversationHistoryRequest(conversation: "c", beforeSeq: 9, limit: 500))["limit"] == .number(200))
        let lease = CloudSessionSetRequest(apiBaseURL: "https://api.example", accessToken: "secret-token", expiresAt: 5, clientVersion: "1.0")
        let wire = try object(lease)
        #expect(wire["api_base_url"] == .string("https://api.example"))
        #expect(wire["access_token"] == .string("secret-token"))
        #expect(wire["expires_at"] == .number(5))
        #expect(!String(describing: lease).contains("secret-token"))
    }

    @Test func cloudEventsDecode() throws {
        func decode(_ name: String, _ json: String) -> DaemonEvent {
            DaemonEvent.decode(name: name, line: Data(json.utf8))
        }
        let changed = decode("cloud-conversation-changed", #"""
        {"event":"cloud-conversation-changed","conversation":"conv_A","rev":7,"seq":12,"transaction":"tx1","change":{"kind":"read-cursor","participant":"user_b","seq":4}}
        """#)
        #expect(changed == .cloudConversations(.changed(CloudConversationChanged(conversation: "conv_A", rev: 7, seq: 12, transaction: "tx1",
                                                                                 change: .readCursor(participant: "user_b", seq: 4)))))

        let invite = decode("cloud-conversation-changed", #"""
        {"event":"cloud-conversation-changed","conversation":"conv_A","rev":8,"seq":13,"transaction":"tx2","change":{"kind":"invite","conversation":"conv_A","invite":{"id":"inv_1"}}}
        """#)
        guard case .cloudConversations(.changed(let delivery)) = invite, case .unknown(let kind) = delivery.change else {
            Issue.record("decoded \(invite)")
            return
        }
        #expect(kind == "invite")

        let resynced = decode("cloud-conversation-resynced", #"""
        {"event":"cloud-conversation-resynced","conversation":"conv_A","rev":3,"seq":5,"summary":{"id":"conv_A","owner":"cloud","kind":"dm",
         "title":"","participants":[{"id":"user_a","kind":"human","display_name":"A","role":"owner"},
         {"id":"addr_X","kind":"address","display_name":"b***@c.co"},{"id":"user_c","kind":"human","display_name":"C","left_at":"2026-10-03T00:00:00.000Z"}],
         "last_seq":1,"rev":3,"created_at":"2026-10-03T00:00:00.000Z","updated_at":"2026-10-03T00:00:00.000Z","read_cursors":{}},
         "messages":[{"id":"msg_1","conversation":"conv_A","seq":1,"client_msg_id":"c1","author":"user_a","parts":[{"type":"text","text":"hi"}],
         "created_at":"2026-10-03T00:00:00.000Z","reactions":[]}]}
        """#)
        guard case .cloudConversations(.resynced(let page)) = resynced else { Issue.record("decoded \(resynced)"); return }
        #expect(page.summary.kind == "dm")
        #expect(page.summary.participants.map(\.kind) == [.human, .address, .human])
        #expect(page.summary.participants[2].leftAt != nil)
        #expect(page.messages.map(\.seq) == [1])

        let inbox = decode("cloud-inbox-changed", #"""
        {"event":"cloud-inbox-changed","seq":4,"transaction":"tx","entries":[{"conversation":"conv_A","rev":3,"kind":"dm","title":"",
         "last_seq":1,"last_at":"2026-10-03T00:00:00.000Z","preview":"A: hi","dm_peer":"user_b","removed":false,"unread":1,"mentions":0,
         "counts_rev":3,"pinned":true,"pin_position":2,"muted":false,"archived":false,"archived_seq":0,"marked_unread":false}]}
        """#)
        guard case .cloudConversations(.inboxChanged(let entries)) = inbox, let entry = entries.entries.first else {
            Issue.record("decoded \(inbox)")
            return
        }
        #expect(entry.dmPeer == "user_b")
        #expect(entry.pinPosition == 2)
        #expect(entry.isListed)

        // The daemon names the lease's account on owner events; older daemons do not.
        let named = decode("cloud-inbox-changed", #"{"event":"cloud-inbox-changed","seq":5,"account":"user_a","entries":[]}"#)
        #expect(named == .cloudConversations(.inboxChanged(CloudInboxChanged(seq: 5, entries: [], account: "user_a"))))
        let namedChange = decode("cloud-conversation-changed", #"""
        {"event":"cloud-conversation-changed","conversation":"conv_A","rev":7,"seq":12,"account":"user_a","change":{"kind":"read-cursor","participant":"user_b","seq":4}}
        """#)
        guard case .cloudConversations(.changed(let withAccount)) = namedChange else { Issue.record("decoded \(namedChange)"); return }
        #expect(withAccount.account == "user_a")
        guard case .cloudConversations(.resynced(let withoutAccount)) = resynced else { return }
        #expect(withoutAccount.account == nil)

        #expect(decode("cloud-inbox-reset", #"{"event":"cloud-inbox-reset","seq":9}"#) == .cloudConversations(.inboxReset(seq: 9)))
        #expect(decode("cloud-subscription-state", #"{"event":"cloud-subscription-state","scope":"conversation","conversation":"conv_A","state":"closed","reason":"forbidden"}"#)
            == .cloudConversations(.subscriptionState(CloudSubscriptionState(scope: "conversation", conversation: "conv_A", state: "closed",
                                                                              reason: "forbidden"))))
        #expect(decode("cloud-session-needed", #"{"event":"cloud-session-needed","reason":"expiring","expires_at":99}"#)
            == .cloudConversations(.sessionNeeded(CloudSessionNeeded(reason: "expiring", expiresAt: 99))))
    }

    @Test func opResultLiftsTheCreatedConversation() throws {
        let json = #"""
        {"value":{"conversation":{"id":"conv_dm_A","owner":"cloud","kind":"dm","title":"","participants":[],"last_seq":0,"rev":1,
         "created_at":"2026-10-03T00:00:00.000Z","updated_at":"2026-10-03T00:00:00.000Z","read_cursors":{}},"invite":{"ok":true}},
         "replayed":true,"transaction":"tx","stream":"conv:conv_dm_A","sequence":3}
        """#
        let result = try JSONDecoder().decode(CloudConversationOpResult.self, from: Data(json.utf8))
        #expect(result.conversation?.id == "conv_dm_A")
        #expect(result.invite == CloudConversationOpResult.InviteOutcome(ok: true))
        #expect(result.replayed)
        #expect(result.rev == nil)
    }

    /// The daemon's reject carries `reason` and `retryable` next to
    /// `error_code`; both reach the caller (home-cloud-proxy.md section 6).
    @Test func aRawRejectKeepsItsReasonAndRetryable() async throws {
        let identify = ConnectionTests.identify.replacingOccurrences(of: #""attach-initial-size""#,
                                                                     with: #""attach-initial-size","cloud-conversations-v1""#)
        let server = try FakeDaemonServer(handler: { request in
            let id = request["id"]?.intValue ?? 0
            switch request["cmd"]?.stringValue {
            case "identify": return [#"{"id":\#(id),"ok":true,"data":\#(identify)}"#]
            case "set-client-info", "subscribe": return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            case "cloud-conversation-op":
                return [#"{"id":\#(id),"ok":false,"error":"not reachable","error_code":"cloud_conversation_rejected","reason":"not_reachable","retryable":false}"#]
            default:
                return [#"{"id":\#(id),"ok":false,"error":"the cloud is unavailable","error_code":"cloud_unavailable","reason":"unavailable","retryable":true}"#]
            }
        })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        let client = CloudConversationClient(connection)
        await #expect {
            _ = try await client.op(CloudConversationOpRequest(conversation: nil, idempotencyKey: "k", op: .dmOpen(peer: .participant("user_b"))))
        } throws: { error in
            guard let error = error as? DaemonError, case .command(_, _, let code, _, let retryable) = error else { return false }
            return code == "cloud_conversation_rejected" && error.rejectReason == "not_reachable" && retryable == false
        }
        await #expect {
            _ = try await client.inboxList(limit: 10)
        } throws: { error in
            guard let error = error as? DaemonError, case .command(_, _, let code, _, let retryable) = error else { return false }
            return code == "cloud_unavailable" && error.rejectReason == "unavailable" && retryable == true
        }
        await connection.close()
    }
}
