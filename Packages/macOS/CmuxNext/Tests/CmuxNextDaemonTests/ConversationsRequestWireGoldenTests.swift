import Foundation
import Testing
@testable import CmuxNextDaemon

/// The wire golden of every request in Sources/CmuxNextDaemon/Conversations: the line each
/// one sends today is recorded in cmux-tui/spec/fixtures/conversation-requests/lines.json and compared
/// here as JSON (key order does not count). The migration to the generated `<Name>Request` types
/// (CmuxNextWireGen RequestEmitter) must keep these goldens green. The daemon side reads the same file
/// (cmux-tui-core server/conversation_wire_tests.rs): it parses every line with the server's own
/// `Request` parse and decodes every document field (op, participants, parts, derived images) as its
/// handler does.
///
/// Dictionary-valued fields, whose keys neither coder renames (WireKeyInventory.dictionaryFields):
/// `conversation-create.participants`, `conversation-op.op`, `conversation-inbox-op.op`,
/// `cloud-inbox-op.op`, `conversation-attachment-upload.poster` and `.preview`, and
/// `conversation-import.messages.parts`. Today each holds a struct or an enum with explicit snake-case
/// keys (`ConversationParticipant`, `ConversationOp`, `ConversationInboxOpRequest.Op`,
/// `ConversationDerivedImageDeclaration`) or a `JSONValue`; after the migration the caller passes those
/// same keys. The goldens pin them, `question.answer`'s caller-authored question ids included.
struct ConversationsRequestWireGoldenTests {
    /// A request of the directory, encoded the way `DaemonConnection` sends it.
    struct Encoded: Sendable {
        /// The request's Swift type.
        let type: String
        let encode: @Sendable () throws -> Data

        init<R: DaemonRequest>(_ request: R) {
            type = String(describing: R.self)
            encode = { try WireCoding.encodeRequest(request, id: 1) }
        }
    }

    private static let hashA = String(repeating: "a", count: 64)
    private static let hashB = String(repeating: "b", count: 64)
    private static let hashC = String(repeating: "c", count: 64)

    private static let me = ConversationParticipant(id: "user_local", kind: .human, displayName: "Me")
    private static let mux = ConversationParticipant(
        id: "agent_mux", kind: .agent, displayName: "Mux", agentClass: "mux", acpSession: "s-1"
    )

    private static let image = ConversationAttachment(
        hash: hashA, name: "a.png", mimeType: "image/png", byteCount: 2048, width: 640, height: 480,
        preview: ConversationDerivedImage(hash: hashB, mimeType: "image/webp", byteCount: 512)
    )
    private static let video = ConversationAttachment(
        hash: hashC, name: "clip.mov", mimeType: "video/quicktime", byteCount: 1_048_576, width: 1920, height: 1080,
        durationMs: 4500, poster: ConversationDerivedImage(hash: hashB, mimeType: "image/jpeg", byteCount: 30000)
    )

    private static func op(_ key: String, actor: String? = nil, transaction: String? = nil,
                           _ op: ConversationOp) -> Encoded {
        Encoded(ConversationOpRequest(
            conversation: "c1", idempotencyKey: key, actor: actor,
            transaction: transaction.map { ClientTransactionID(rawValue: $0) }, op: op
        ))
    }

    /// The request each fixture entry records, by its `name`.
    static let requests: [String: Encoded] = [
        "conversation-list": Encoded(ListConversationsRequest()),
        "conversation-snapshot": Encoded(ConversationSnapshotRequest(conversation: "c1", tail: 50)),
        "conversation-snapshot clamps tail up to 1": Encoded(ConversationSnapshotRequest(conversation: "c1", tail: 0)),
        "conversation-snapshot clamps tail down to 500": Encoded(ConversationSnapshotRequest(conversation: "c1", tail: 900)),
        "conversation-history": Encoded(ConversationHistoryRequest(conversation: "c1", beforeSeq: 120, limit: 50)),
        "conversation-history clamps limit up to 1": Encoded(ConversationHistoryRequest(
            conversation: "c1", beforeSeq: 120, limit: 0
        )),
        "conversation-thread": Encoded(ConversationThreadRequest(conversation: "c1", root: "m-1", afterSeq: 0, limit: 50)),
        "conversation-thread clamps limit down to 500": Encoded(ConversationThreadRequest(
            conversation: "c1", root: "m-1", afterSeq: 9, limit: 9999
        )),
        "conversation-link-resolve": Encoded(ConversationLinkResolveRequest(url: "cmux://conversation/c1/message/m-2")),
        "conversation-create": Encoded(CreateConversationRequest(idempotencyKey: "k-1", title: "Plan", participants: [me, mux])),
        "conversation-create with an actor": Encoded(CreateConversationRequest(
            idempotencyKey: "k-1", actor: "user_local", title: "Plan", participants: [me]
        )),
        "conversation-op message.send text in a thread": op("cm-1", transaction: "tx-1", .send(
            clientMsgID: "cm-1",
            parts: [.text("hi @mux", runs: [ConversationTextRun(start: 3, length: 4, mention: "agent_mux")])],
            replyTo: ConversationPartRef(messageID: "m-1", partIndex: 0), threadRoot: "m-1"
        )),
        "conversation-op message.send attachment, link preview and work": op("cm-2", actor: "user_local", .send(
            clientMsgID: "cm-2",
            parts: [
                .attachment(image),
                .attachment(video),
                .linkPreview(ConversationLinkPreview(
                    url: "https://example.com/a", title: "Example", site: "example.com",
                    image: ConversationDerivedImage(hash: hashB, mimeType: "image/jpeg", byteCount: 30000)
                )),
                .work(session: "s-1", host: nil, status: "running", preview: "building"),
            ],
            replyTo: nil
        )),
        "conversation-op message.edit": op("k-edit", .edit(messageID: "m-2", parts: [.text("fixed", runs: [])])),
        "conversation-op message.retract": op("k-retract", .retract(messageID: "m-2")),
        "conversation-op reaction.add tapback": op("k-react", .addReaction(
            messageID: "m-2", partIndex: 0, kind: .tapback("love")
        )),
        "conversation-op reaction.remove emoji": op("k-unreact", .removeReaction(
            messageID: "m-2", partIndex: 1, kind: .emoji("\u{1F389}")
        )),
        "conversation-op read_cursor.set": op("k-read", .setReadCursor(seq: 42)),
        "conversation-op participants.add": op("k-add", .addParticipant(mux)),
        "conversation-op title.set": op("k-title", .setTitle("Renamed")),
        // `answer` is a JSONValue document: its keys (question ids) go out as given.
        "conversation-op question.answer": op("k-answer", .answerQuestion(
            messageID: "m-3", partIndex: 0,
            answer: .object(["selections": .object([
                "deployTarget": .object(["option_ids": .array([.string("prod")])]),
                "q_note": .object(["other": .string("after 5pm")]),
            ])])
        )),
        "conversation-op thread.update": op("k-thread", .updateThread(
            root: "m-1", title: "Ship it", status: "resolved", owner: nil
        )),
        "conversation-typing": Encoded(ConversationTypingRequest(conversation: "c1", on: true)),
        "conversation-typing with an actor": Encoded(ConversationTypingRequest(
            conversation: "c1", actor: "agent_mux", on: false
        )),
        "conversation-agent-token": Encoded(ConversationAgentTokenRequest(participant: "agent_mux")),
        "conversation-bind": Encoded(ConversationBindRequest(participant: "agent_mux", token: "tok-1")),
        "conversation-search": Encoded(ConversationSearchRequest(query: "deploy", limit: 20)),
        "conversation-live": Encoded(ConversationLiveRequest(conversation: "c1")),
        "cloud-conversation-live": Encoded(CloudConversationLiveRequest(conversation: "c1")),
        "conversation-run": Encoded(ConversationRunRequest(conversation: "c1", run: "r-1")),
        "conversation-run after a rev": Encoded(ConversationRunRequest(conversation: "c1", run: "r-1", afterRev: 7)),
        "cloud-conversation-run": Encoded(CloudConversationRunRequest(conversation: "c1", agent: "agent_mux", run: "r-1")),
        "cloud-conversation-run after a seq": Encoded(CloudConversationRunRequest(
            conversation: "c1", agent: "agent_mux", run: "r-1", afterSeq: 3
        )),
        // `parts` are JSONValue documents, sent as the owner stores them.
        "conversation-import": Encoded(ConversationImportRequest(conversation: "c1", messages: [
            ConversationImportedMessage(
                id: nil, clientMsgID: "cm-1", author: "user_local",
                parts: [.object(["type": .string("text"), "text": .string("hello")])],
                createdAt: "2026-10-06T03:06:01.998Z"
            ),
            ConversationImportedMessage(
                id: "m-9", clientMsgID: "cm-2", author: "agent_mux",
                parts: [.object([
                    "type": .string("attachment"), "hash": .string(hashA), "name": .string("a.png"),
                    "mime_type": .string("image/png"), "byte_count": .number(2048),
                ])],
                createdAt: "2026-10-06T03:06:02.000Z"
            ),
        ])),
        "home-inbox": Encoded(HomeInboxRequest()),
        "home-inbox of the local owner": Encoded(HomeInboxRequest(owners: ["local"])),
        "cloud-inbox-op inbox.pin": Encoded(CloudInboxOpRequest(
            conversation: "c1", idempotencyKey: "k-2", op: .pin(true, position: 3)
        )),
        "cloud-inbox-op inbox.mute until": Encoded(CloudInboxOpRequest(
            conversation: "c1", idempotencyKey: "k-3", op: .mute(true, until: 1_767_225_600_000)
        )),
        "conversation-inbox-op inbox.pin": Encoded(ConversationInboxOpRequest(conversation: "c1", op: .pin(true, position: 2))),
        // An unpin drops the position it was given.
        "conversation-inbox-op unpin": Encoded(ConversationInboxOpRequest(conversation: "c1", op: .pin(false, position: 7))),
        "conversation-inbox-op inbox.mark_unread": Encoded(ConversationInboxOpRequest(
            conversation: "c1", op: .markUnread(true)
        )),
        "conversation-attachment-upload begin image": Encoded(ConversationAttachmentUploadRequest.begin(
            conversation: "c1", attachment: image
        )),
        "conversation-attachment-upload begin video": Encoded(ConversationAttachmentUploadRequest.begin(
            conversation: "c1", attachment: video
        )),
        "conversation-attachment-upload chunk": Encoded(ConversationAttachmentUploadRequest.chunk(
            upload: "u-1", piece: .preview, offset: 0, bytes: Data("abc".utf8)
        )),
        "conversation-attachment-upload commit": Encoded(ConversationAttachmentUploadRequest.commit(upload: "u-1")),
        "conversation-attachment-upload cancel": Encoded(ConversationAttachmentUploadRequest.cancel(upload: "u-1")),
        "conversation-attachment-read": Encoded(ConversationAttachmentReadRequest(
            conversation: "c1", hash: hashA, variant: .original, offset: 0, length: 4_194_304
        )),
        "conversation-attachment-read preview": Encoded(ConversationAttachmentReadRequest(
            conversation: "c1", hash: hashA, variant: .preview, offset: 65536, length: 1024
        )),
    ]

    @Test func sendsItsGoldenLines() throws {
        let recorded = try Self.fixture()
        #expect(Set(recorded.keys) == Set(Self.requests.keys), "fixture and test name different requests")
        for (name, golden) in recorded.sorted(by: { $0.key < $1.key }) {
            guard let request = Self.requests[name] else { continue }
            let line = try JSONDecoder().decode(JSONValue.self, from: request.encode())
            #expect(line == golden, "\(name)")
        }
    }

    /// Every request type declared in Sources/CmuxNextDaemon/Conversations has a golden. The list is read
    /// from the source, so a type added there needs one.
    @Test func everyConversationsRequestTypeHasAGolden() throws {
        let directory = try Self.repositoryRoot()
            .appendingPathComponent("Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Conversations")
        let declaration = try NSRegularExpression(pattern: #"\bstruct\s+(\w+)\s*:[^{]*\bDaemonRequest\b"#)
        var declared: Set<String> = []
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in declaration.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                if let name = Range(match.range(at: 1), in: source) { declared.insert(String(source[name])) }
            }
        }
        // When the migration deletes these structs, this set must come from the generated Conversations
        // types instead: an empty directory does not pass as "every type has a golden".
        try #require(!declared.isEmpty, "no DaemonRequest type in \(directory.path)")
        let covered = Set(Self.requests.values.map(\.type))
        #expect(declared.subtracting(covered).isEmpty, "no golden: \(declared.subtracting(covered).sorted())")
        #expect(covered.subtracting(declared).isEmpty, "not in the directory: \(covered.subtracting(declared).sorted())")
    }

    /// Every key a golden sends is a request field of its command in cmux-tui/spec/sdk-schema.json, and the
    /// command is one the macOS app calls, so RequestEmitter generates a type with each of these members.
    @Test func sendsOnlySchemaFields() throws {
        let root = try Self.repositoryRoot()
        let schema = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/sdk-schema.json"))
        )
        guard case .object(let document) = schema, case .object(let commands)? = document["commands"] else {
            Issue.record("sdk-schema.json has no commands")
            return
        }
        for (name, golden) in try Self.fixture() {
            guard case .object(let line) = golden, case .string(let command)? = line["cmd"],
                  case .object(let entry)? = commands[command],
                  case .array(let clients)? = entry["clients"], clients.contains(.string("macos")) else {
                Issue.record("\(name): not a macos command of sdk-schema.json")
                continue
            }
            let fields: [String: JSONValue]
            if case .object(let request)? = entry["request"], case .object(let declared)? = request["fields"] {
                fields = declared
            } else {
                fields = [:]
            }
            let extra = Set(line.keys).subtracting(["id", "cmd"]).subtracting(fields.keys)
            #expect(extra.isEmpty, "\(name): not schema fields of \(command): \(extra.sorted())")
        }
    }

    // Fixture ---------------------------------------------------------------

    /// `name -> line` of lines.json.
    private static func fixture() throws -> [String: JSONValue] {
        let data = try Data(contentsOf: repositoryRoot()
            .appendingPathComponent("cmux-tui/spec/fixtures/conversation-requests/lines.json"))
        guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let entries)? = root["requests"] else { return [:] }
        var lines: [String: JSONValue] = [:]
        for case .object(let entry) in entries {
            guard case .string(let name)? = entry["name"], let line = entry["line"] else { continue }
            #expect(lines.updateValue(line, forKey: name) == nil, "\(name) twice")
        }
        return lines
    }

    private static func repositoryRoot() throws -> URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("cmux-tui/spec").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no cmux-tui/spec above \(#filePath)")
            root = parent
        }
        return root
    }
}
