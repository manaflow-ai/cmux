import Foundation
import Testing
@testable import CmuxNextDaemon

/// The wire golden of every request in Sources/CmuxNextDaemon/CloudConversations: the
/// line each one sends today, compared as JSON (key order does not count). The migration to the
/// generated `<Name>Request` types (CmuxNextWireGen RequestEmitter) must send the same lines; the
/// generated coder writes each member under its schema wire name, so a golden that holds here and
/// after the migration proves the bytes did not change.
///
/// Dictionary-valued fields (WireKeyInventory.dictionaryFields), whose keys neither coder renames:
/// `cloud-conversation-op.op` (a `JsonValue` document, today the `CloudConversationOp` enum, which
/// writes its keys by hand) and `cloud-attachment-upload.poster` / `.preview` (today
/// `ConversationDerivedImageDeclaration`, whose explicit CodingKeys are the stored snake-case keys).
/// The goldens pin the keys those documents carry, which the callers must pass after the migration.
///
/// Two generated names differ from the hand-written ones: `cloud-requests-list` becomes
/// `CloudRequestsListRequest` (today `CloudMessageRequestsRequest`) and `cloud-selfhost-info`
/// becomes `CloudSelfhostInfoRequest` (today `CloudSelfHostInfoRequest`).
struct CloudConversationsRequestWireGoldenTests {
    /// One request's expected line, `id` and `cmd` included.
    struct Golden: Sendable, CustomTestStringConvertible {
        let name: String
        let encode: @Sendable () throws -> Data
        let command: String
        let capability: String?
        let fields: [String: JSONValue]

        init<R: DaemonRequest>(_ name: String, _ request: R, _ fields: [String: JSONValue]) {
            self.name = name
            encode = { try WireCoding.encodeRequest(request, id: 1) }
            command = R.command
            capability = R.requiredCapability
            var line = fields
            line["id"] = .number(1)
            line["cmd"] = .string(R.command)
            self.fields = line
        }

        var testDescription: String { name }
    }

    /// The `JsonValue` fields of the directory's commands: documents whose keys the caller writes.
    static let dictionaryFields: Set = [
        "cloud-conversation-op.op", "cloud-attachment-upload.poster", "cloud-attachment-upload.preview",
    ]

    private static let movie = ConversationAttachment(
        hash: "h-movie", name: "a.mov", mimeType: "video/quicktime", byteCount: 4096, width: 640, height: 480,
        durationMs: 1500, poster: ConversationDerivedImage(hash: "h-poster", mimeType: "image/jpeg", byteCount: 64)
    )
    private static let photo = ConversationAttachment(
        hash: "h-photo", name: "a.png", mimeType: "image/png", byteCount: 2048,
        preview: ConversationDerivedImage(hash: "h-preview", mimeType: "image/webp", byteCount: 32)
    )
    private static let participant = ConversationParticipant(
        id: "agent_mux", kind: .agent, displayName: "Mux", agentClass: "mux", ownerUser: "user_1"
    )

    static let goldens: [Golden] = attachmentGoldens + readGoldens + opGoldens + subscriptionGoldens + leaseGoldens

    private static let attachmentGoldens: [Golden] = [
        Golden("cloud-attachment-read",
               CloudAttachmentReadRequest(read: ConversationAttachmentReadRequest(
                   conversation: "c-1", hash: "h-photo", variant: .preview, offset: 0, length: 65536)),
               ["conversation": .string("c-1"), "hash": .string("h-photo"), "variant": .string("preview"),
                "offset": .number(0), "length": .number(65536)]),
        // `poster` is a JsonValue document: the declaration's keys are already the stored snake-case keys.
        Golden("cloud-attachment-upload begin with a poster",
               CloudAttachmentUploadRequest(step: .begin(conversation: "c-1", attachment: movie)),
               ["op": .string("begin"), "conversation": .string("c-1"), "sha256": .string("h-movie"),
                "byte_count": .number(4096), "mime_type": .string("video/quicktime"), "name": .string("a.mov"),
                "width": .number(640), "height": .number(480), "duration_ms": .number(1500),
                "poster": .object(["sha256": .string("h-poster"), "byte_count": .number(64),
                                   "mime_type": .string("image/jpeg")])]),
        Golden("cloud-attachment-upload begin with a preview",
               CloudAttachmentUploadRequest(step: .begin(conversation: "c-1", attachment: photo)),
               ["op": .string("begin"), "conversation": .string("c-1"), "sha256": .string("h-photo"),
                "byte_count": .number(2048), "mime_type": .string("image/png"), "name": .string("a.png"),
                "preview": .object(["sha256": .string("h-preview"), "byte_count": .number(32),
                                    "mime_type": .string("image/webp")])]),
        Golden("cloud-attachment-upload chunk",
               CloudAttachmentUploadRequest(step: .chunk(upload: "u-1", piece: .original, offset: 8, bytes: Data("abc".utf8))),
               ["op": .string("chunk"), "upload": .string("u-1"), "piece": .string("original"), "offset": .number(8),
                "data": .string("YWJj")]),
        Golden("cloud-attachment-upload commit", CloudAttachmentUploadRequest(step: .commit(upload: "u-1")),
               ["op": .string("commit"), "upload": .string("u-1")]),
        Golden("cloud-attachment-upload cancel", CloudAttachmentUploadRequest(step: .cancel(upload: "u-1")),
               ["op": .string("cancel"), "upload": .string("u-1")]),
    ]

    /// The reads clamp their counts to the schema's ranges before they send them.
    private static let readGoldens: [Golden] = [
        Golden("cloud-inbox-list", CloudInboxListRequest(), [:]),
        Golden("cloud-inbox-list with every field, clamped",
               CloudInboxListRequest(limit: 500, includeArchived: true),
               ["limit": .number(200), "include_archived": .bool(true)]),
        Golden("cloud-inbox-list raised to one", CloudInboxListRequest(limit: 0, includeArchived: false),
               ["limit": .number(1), "include_archived": .bool(false)]),
        Golden("cloud-conversation-snapshot clamped", CloudConversationSnapshotRequest(conversation: "c-1", tail: 80),
               ["conversation": .string("c-1"), "tail": .number(50)]),
        Golden("cloud-conversation-history raised to one",
               CloudConversationHistoryRequest(conversation: "c-1", beforeSeq: 42, limit: 0),
               ["conversation": .string("c-1"), "before_seq": .number(42), "limit": .number(1)]),
        Golden("cloud-conversation-thread clamped",
               CloudConversationThreadRequest(conversation: "c-1", root: "m-root", afterSeq: 7, limit: 500),
               ["conversation": .string("c-1"), "root": .string("m-root"), "after_seq": .number(7), "limit": .number(200)]),
        Golden("cloud-requests-list", CloudMessageRequestsRequest(), [:]),
    ]

    /// `cloud-conversation-op` with every op kind: `op` is the document the owner reads.
    private static let opGoldens: [Golden] = {
        func op(_ name: String, conversation: String? = "c-1", origin: String? = "user", _ op: CloudConversationOp,
                _ document: [String: JSONValue]) -> Golden {
            var fields: [String: JSONValue] = ["idempotency_key": .string("k-1"), "op": .object(document)]
            fields["conversation"] = conversation.map(JSONValue.string)
            fields["origin"] = origin.map(JSONValue.string)
            return Golden("cloud-conversation-op \(name)",
                          CloudConversationOpRequest(conversation: conversation, idempotencyKey: "k-1", origin: origin, op: op),
                          fields)
        }
        let textPart = ConversationPart.text("hi @mux", runs: [ConversationTextRun(start: 3, length: 4, mention: "agent_mux")])
        let textDocument = JSONValue.object([
            "type": .string("text"), "text": .string("hi @mux"),
            "runs": .array([.object(["start": .number(3), "length": .number(4), "mention": .string("agent_mux")])]),
        ])
        let participantDocument = JSONValue.object([
            "id": .string("agent_mux"), "kind": .string("agent"), "display_name": .string("Mux"),
            "agent_class": .string("mux"), "owner_user": .string("user_1"),
        ])
        return [
            op("dm.open with a participant", conversation: nil, .dmOpen(peer: .participant("user_2")),
               ["kind": .string("dm.open"), "peer": .string("user_2")]),
            op("dm.open with an email", conversation: nil, origin: nil, .dmOpen(peer: .address(.email("a@b.test"))),
               ["kind": .string("dm.open"), "peer": .object(["email": .string("a@b.test")])]),
            op("conversation.create", conversation: nil, .create(title: "Team", participants: [participant]),
               ["kind": .string("conversation.create"), "title": .string("Team"), "participants": .array([participantDocument])]),
            op("conversation.create untitled", conversation: nil, .create(title: nil, participants: []),
               ["kind": .string("conversation.create"), "participants": .array([])]),
            op("participants.add", .addParticipant(participant),
               ["kind": .string("participants.add"), "participant": participantDocument]),
            op("participants.remove", .removeParticipant("user_2"),
               ["kind": .string("participants.remove"), "participant": .string("user_2")]),
            op("message.send", .send(clientMsgID: "k-1", parts: [textPart], replyTo: nil),
               ["kind": .string("message.send"), "client_msg_id": .string("k-1"), "parts": .array([textDocument])]),
            op("message.send with every field",
               .send(clientMsgID: "k-1", parts: [textPart, .attachment(photo)],
                     replyTo: ConversationPartRef(messageID: "m-0", partIndex: 1), threadRoot: "m-root"),
               ["kind": .string("message.send"), "client_msg_id": .string("k-1"), "parts": .array([
                   textDocument,
                   .object([
                       "type": .string("attachment"), "hash": .string("h-photo"), "name": .string("a.png"),
                       "mime_type": .string("image/png"), "byte_count": .number(2048),
                       "preview": .object(["hash": .string("h-preview"), "mime_type": .string("image/webp"),
                                           "byte_count": .number(32)]),
                   ]),
               ]), "reply_to": .object(["message_id": .string("m-0"), "part_index": .number(1)]),
               "thread_root": .string("m-root")]),
            op("message.edit", .edit(messageID: "m-1", parts: [textPart]),
               ["kind": .string("message.edit"), "message_id": .string("m-1"), "parts": .array([textDocument])]),
            op("message.retract", .retract(messageID: "m-1"),
               ["kind": .string("message.retract"), "message_id": .string("m-1")]),
            op("reaction.add", .addReaction(messageID: "m-1", partIndex: 0, kind: .tapback("heart")),
               ["kind": .string("reaction.add"), "message_id": .string("m-1"), "part_index": .number(0),
                "reaction": .object(["tapback": .string("heart")])]),
            op("reaction.remove", .removeReaction(messageID: "m-1", partIndex: 2, kind: .emoji("\u{1F389}")),
               ["kind": .string("reaction.remove"), "message_id": .string("m-1"), "part_index": .number(2),
                "reaction": .object(["emoji": .string("\u{1F389}")])]),
            op("read_cursor.set", .setReadCursor(seq: 99), ["kind": .string("read_cursor.set"), "seq": .number(99)]),
            op("title.set", .setTitle("T"), ["kind": .string("title.set"), "title": .string("T")]),
            op("conversation.settings.set", .setSettings(wakePolicy: "mentions"),
               ["kind": .string("conversation.settings.set"), "wake_policy": .string("mentions")]),
            op("invite.create", .createInvite(address: .phone("+15550100"), displayName: "Ann", locale: "en"),
               ["kind": .string("invite.create"), "address": .object(["phone": .string("+15550100")]),
                "display_name": .string("Ann"), "locale": .string("en")]),
            op("invite.create without a locale", .createInvite(address: .email("a@b.test"), displayName: "Ann", locale: nil),
               ["kind": .string("invite.create"), "address": .object(["email": .string("a@b.test")]),
                "display_name": .string("Ann")]),
            op("thread.update", .updateThread(root: "m-root", title: "T", status: "done", owner: "user_1"),
               ["kind": .string("thread.update"), "root": .string("m-root"), "title": .string("T"),
                "status": .string("done"), "owner": .string("user_1")]),
            op("thread.update with only the root", .updateThread(root: "m-root", title: nil, status: nil, owner: nil),
               ["kind": .string("thread.update"), "root": .string("m-root")]),
            op("invite.accept_verified", .acceptRequest, ["kind": .string("invite.accept_verified")]),
            op("request.dismiss", .dismissRequest(block: true), ["kind": .string("request.dismiss"), "block": .bool(true)]),
        ]
    }()

    private static let subscriptionGoldens: [Golden] = [
        Golden("cloud-conversation-subscribe", CloudConversationSubscribeRequest(conversation: "c-1"),
               ["conversation": .string("c-1")]),
        Golden("cloud-conversation-unsubscribe", CloudConversationUnsubscribeRequest(conversation: "c-1"),
               ["conversation": .string("c-1")]),
        Golden("cloud-conversation-typing", CloudConversationTypingRequest(conversation: "c-1", on: true),
               ["conversation": .string("c-1"), "on": .bool(true)]),
        Golden("cloud-conversation-typing stopped", CloudConversationTypingRequest(conversation: "c-1", on: false),
               ["conversation": .string("c-1"), "on": .bool(false)]),
        Golden("cloud-inbox-subscribe", CloudInboxSubscribeRequest(), [:]),
        Golden("cloud-inbox-unsubscribe", CloudInboxUnsubscribeRequest(), [:]),
    ]

    /// The leases: the session's token and the host replica's install token.
    private static let leaseGoldens: [Golden] = [
        Golden("cloud-session-set bearer",
               CloudSessionSetRequest(apiBaseURL: "https://api.test", accessToken: "tok", expiresAt: 1_700_000_000_000),
               ["api_base_url": .string("https://api.test"), "access_token": .string("tok"),
                "expires_at": .number(1_700_000_000_000)]),
        Golden("cloud-session-set bearer with every field",
               CloudSessionSetRequest(apiBaseURL: "https://api.test", accessToken: "tok", expiresAt: 5, clientVersion: "1.2"),
               ["api_base_url": .string("https://api.test"), "access_token": .string("tok"), "expires_at": .number(5),
                "client_version": .string("1.2")]),
        // A self-hosted lease sends no token and no expiry.
        Golden("cloud-session-set tailscale",
               CloudSessionSetRequest.tailscale(apiBaseURL: "http://chat.tail0.ts.net", clientVersion: "1.2"),
               ["api_base_url": .string("http://chat.tail0.ts.net"), "auth": .string("tailscale"),
                "client_version": .string("1.2")]),
        Golden("cloud-session-clear", CloudSessionClearRequest(), [:]),
        Golden("cloud-session-status", CloudSessionStatusRequest(), [:]),
        Golden("cloud-selfhost-info", CloudSelfHostInfoRequest(), [:]),
        Golden("cloud-host-replica-set",
               CloudHostReplicaSetRequest(apiBaseURL: "https://api.test", installToken: "inst", expiresAt: 9, hostName: "Mac"),
               ["api_base_url": .string("https://api.test"), "install_token": .string("inst"), "expires_at": .number(9),
                "host_name": .string("Mac")]),
        Golden("cloud-host-replica-set with every field",
               CloudHostReplicaSetRequest(apiBaseURL: "https://api.test", installToken: "inst", expiresAt: 9,
                                          clientVersion: "1.2", hostName: "Mac"),
               ["api_base_url": .string("https://api.test"), "install_token": .string("inst"), "expires_at": .number(9),
                "client_version": .string("1.2"), "host_name": .string("Mac")]),
        // `purge` goes out even when false, which is the schema's default.
        Golden("cloud-host-replica-clear", CloudHostReplicaClearRequest(purge: false), ["purge": .bool(false)]),
        Golden("cloud-host-replica-clear purging", CloudHostReplicaClearRequest(purge: true), ["purge": .bool(true)]),
        Golden("cloud-host-replica-status", CloudHostReplicaStatusRequest(), [:]),
    ]

    @Test(arguments: goldens)
    func sendsItsGoldenLine(_ golden: Golden) throws {
        let line = try JSONDecoder().decode(JSONValue.self, from: golden.encode())
        #expect(line == .object(golden.fields))
    }

    /// Every sent key is a request field of its command in cmux-tui/spec/sdk-schema.json, every
    /// required field is sent, and the command lists the macos client, so RequestEmitter generates
    /// a type with each of these members.
    @Test func sendsSchemaFields() throws {
        let commands = try Self.schemaCommands()
        for golden in Self.goldens {
            let fields = try Self.requestFields(golden.command, in: commands)
            let sent = Set(golden.fields.keys).subtracting(["id", "cmd"])
            let extra = sent.subtracting(fields.keys)
            #expect(extra.isEmpty, "\(golden.name): not schema fields of \(golden.command): \(extra.sorted())")
            let required = fields.compactMap { entry -> String? in
                guard case .object(let spec) = entry.value, spec["presence"] == JSONValue.string("required") else {
                    return nil
                }
                return entry.key
            }
            let missing = Set(required).subtracting(sent)
            #expect(missing.isEmpty, "\(golden.name): required fields of \(golden.command) not sent: \(missing.sorted())")
        }
    }

    /// The `JsonValue` request fields of the directory's commands are exactly the listed dictionary
    /// fields, so no document the generated type takes as given is left out of the list.
    @Test func dictionaryFieldsAreTheJsonValueFields() throws {
        let commands = try Self.schemaCommands()
        var documents: Set<String> = []
        for command in Set(Self.goldens.map(\.command)) {
            for (name, spec) in try Self.requestFields(command, in: commands) {
                guard case .object(let field) = spec, case .object(let type)? = field["type"] else { continue }
                if type["kind"] == JSONValue.string("ref"), type["name"] == JSONValue.string("JsonValue") {
                    documents.insert("\(command).\(name)")
                }
            }
        }
        #expect(documents == Self.dictionaryFields)
    }

    /// A hand-written type that gates on a capability gates on the schema's one. The generated
    /// types take every command's capability from the schema (MethodTable), so the commands
    /// written here without one become gated on theirs; this pins which those are.
    @Test func capabilitiesAgreeWithTheSchema() throws {
        let commands = try Self.schemaCommands()
        var ungated: Set<String> = []
        for golden in Self.goldens {
            guard case .object(let spec)? = commands[golden.command] else { throw SchemaShapeError.missing(golden.command) }
            guard let capability = golden.capability else {
                ungated.insert(golden.command)
                continue
            }
            #expect(spec["capability"] == JSONValue.string(capability), "\(golden.command): \(capability)")
        }
        #expect(ungated == [
            "cloud-inbox-list", "cloud-conversation-snapshot", "cloud-conversation-history", "cloud-requests-list",
            "cloud-conversation-op", "cloud-conversation-subscribe", "cloud-conversation-unsubscribe",
            "cloud-inbox-subscribe", "cloud-inbox-unsubscribe", "cloud-session-set", "cloud-session-clear",
            "cloud-session-status", "cloud-host-replica-set", "cloud-host-replica-clear", "cloud-host-replica-status",
        ])
    }

    /// Every request type of the directory has a golden.
    @Test func everyCloudConversationsCommandHasAGolden() {
        let covered = Set(Self.goldens.map(\.command))
        let commands: Set = [
            CloudAttachmentReadRequest.command, CloudAttachmentUploadRequest.command, CloudInboxListRequest.command,
            CloudConversationSnapshotRequest.command, CloudConversationHistoryRequest.command,
            CloudConversationThreadRequest.command, CloudMessageRequestsRequest.command,
            CloudConversationOpRequest.command, CloudConversationSubscribeRequest.command,
            CloudConversationUnsubscribeRequest.command, CloudConversationTypingRequest.command,
            CloudInboxSubscribeRequest.command, CloudInboxUnsubscribeRequest.command, CloudSessionSetRequest.command,
            CloudSessionClearRequest.command, CloudSessionStatusRequest.command, CloudSelfHostInfoRequest.command,
            CloudHostReplicaSetRequest.command, CloudHostReplicaClearRequest.command, CloudHostReplicaStatusRequest.command,
        ]
        #expect(commands.count == 20)
        #expect(commands.subtracting(covered).isEmpty)
    }

    /// The request fields of `command`, which must be a macos command of the schema.
    private static func requestFields(_ command: String, in commands: [String: JSONValue]) throws -> [String: JSONValue] {
        guard case .object(let spec)? = commands[command] else { throw SchemaShapeError.missing(command) }
        guard case .array(let clients)? = spec["clients"], clients.contains(.string("macos")) else {
            throw SchemaShapeError.notMacOS(command)
        }
        guard case .object(let request)? = spec["request"], case .object(let fields)? = request["fields"] else {
            return [:]
        }
        return fields
    }

    enum SchemaShapeError: Error {
        case missing(String)
        case notMacOS(String)
        case noSchema
    }

    /// `$.commands` of cmux-tui/spec/sdk-schema.json.
    private static func schemaCommands() throws -> [String: JSONValue] {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("cmux-tui/spec").path) {
            let parent = root.deletingLastPathComponent()
            guard parent.path != root.path else { throw SchemaShapeError.noSchema }
            root = parent
        }
        let data = try Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/sdk-schema.json"))
        guard case .object(let schema) = try JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let commands)? = schema["commands"] else { throw SchemaShapeError.noSchema }
        return commands
    }
}
