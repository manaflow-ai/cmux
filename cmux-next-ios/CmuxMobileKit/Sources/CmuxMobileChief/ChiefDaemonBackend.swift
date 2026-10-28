import CmuxConversationCore
import CmuxMobileAgentChat
import CmuxMobileTransport
import CryptoKit
import Foundation

/// The real Chief: the Mac's Chief conversation owner (the cmux-tui session
/// of the Chief home that every cmux-next build on the Mac shares), reached
/// through the link's `chief` channel, which cmux-mobile-host scopes to the owner's
/// conversations with agents (verify/relay-security.md, "Chief"). Finds the
/// conversation the Mac's Home shows (the oldest one with `agent_mux`, as
/// `HomeChiefName.select`), subscribes, loads pages with
/// `conversation-snapshot` / `conversation-history`, writes with
/// `conversation-op`, and turns `conversation-changed` / `conversation-typing`
/// events into store events. A `rev` gap means events were missed: the store
/// is told to refetch. The phone never creates Chief: the Mac does, with its
/// own idempotent request, when Home opens.
public final class ChiefDaemonBackend: ConversationFileBackend, @unchecked Sendable {
    let core: Core

    public init(client: DaemonClient, identity: ChiefIdentity = .standard, conversationID: String? = nil,
                preferences: ChiefPreferences = ChiefPreferences()) {
        core = Core(client: client, identity: identity, conversationID: conversationID, preferences: preferences)
        control = ChiefControl(client: client)
    }

    /// The brain's engine controls (model, harness, effort, stop) on the same channel.
    public let control: ChiefControl

    /// The Mac's avatar event (cmux-tui events.md `chief-profile-changed`).
    static let profileEvent = "chief-profile-changed"

    /// Draws Chief with the Mac's avatar text (nil: "C"), as an engine
    /// report or a `chief-profile-changed` event gives it.
    public func applyAvatar(_ text: String?) async {
        await core.applyAvatar(text)
    }

    /// Chief's failed turns with the brain's raw error, by message id.
    public var failureLog: ChiefFailureLog { core.failureLog }

    /// The link service of the Chief owner (cmux-mobile-host `chief`).
    public static let service = "chief"

    /// Opens the `chief` channel on `link`.
    public static func open(link: any MacLink, identity: ChiefIdentity = .standard) async throws -> ChiefDaemonBackend {
        let channel = try await link.openChannel(service: service, args: [:])
        return ChiefDaemonBackend(client: DaemonClient(channel: channel), identity: identity)
    }

    /// Answers the question part `partIndex` of `messageID` (`question.answer`).
    /// The Mac counts it only with this iPhone's Face ID approval
    /// (cmux-mobile-host `chief_answers.rs`): `signer` asks for Face ID and signs this
    /// exact answer for this Mac, conversation and question.
    public func answerQuestion(messageID: String, partIndex: Int, answer: JSONValue,
                               signer: any ChiefAnswerSigning) async throws -> ConversationMessage {
        try await core.answer(messageID: messageID, partIndex: partIndex, answer: answer, signer: signer)
    }

    /// Renames the conversation (`title.set`), as the Mac's Chief settings do.
    public func rename(_ title: String) async throws {
        _ = try await core.op(["kind": "title.set", "title": title], expectMessage: false)
    }

    /// Hide Alerts and Send Read Receipts belong to this phone
    /// (``ChiefPreferences``); other list actions do not apply to Chief.
    public func updateListState(_ change: ConversationListStateChange) async throws -> ConversationInfo {
        try await core.updateListState(change)
    }

    public func events() -> AsyncStream<ConversationBackendEvent> {
        let (stream, continuation) = AsyncStream<ConversationBackendEvent>.makeStream(bufferingPolicy: .unbounded)
        Task { await core.run(continuation) }
        return stream
    }

    public func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
        try await core.history(beforeSeq: beforeSeq, limit: limit)
    }

    public func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage {
        try await core.send(draft)
    }

    public func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage {
        try await core.react(messageID: messageID, reaction: reaction)
    }

    public func edit(messageID: String, text: String, textRuns: [ConversationTextRun]) async throws -> ConversationMessage {
        try await edit(messageID: messageID, text: text)
    }

    public func edit(messageID: String, text: String) async throws -> ConversationMessage {
        try await core.op(["kind": "message.edit", "message_id": messageID, "parts": [["type": "text", "text": text]]])
    }

    public func unsend(messageID: String) async throws -> ConversationMessage {
        try await core.op(["kind": "message.retract", "message_id": messageID])
    }

    public func setTyping(_ isTyping: Bool) async {
        await core.typing(isTyping)
    }

    public func markRead(upToSeq: Int) async {
        await core.markRead(upToSeq)
    }

    /// `conversation-attachment-upload` (capability `local-attachments-v1`):
    /// begin by SHA-256, send 2 MiB chunks, commit. The message names the
    /// stored hash in an `attachment` part.
    public func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment {
        let size = ChiefImageSize(data: data)
        let ext = mimeType == "image/png" ? "png" : mimeType == "image/heic" ? "heic" : "jpg"
        return try await core.upload(data, mimeType: mimeType, name: "IMG_\(Int(Date().timeIntervalSince1970)).\(ext)",
                                     width: size.width, height: size.height, file: nil)
    }

    public func uploadFileAttachment(_ data: Data, info: ConversationFileInfo) async throws -> ConversationAttachment {
        try await core.upload(data, mimeType: info.mimeType, name: info.name, width: nil, height: nil, file: info)
    }

    public func close() {
        Task { await core.close() }
    }

    /// What the phone says when the Mac has no Chief conversation yet.
    public static let notStarted = String(localized: "Chief hasn't started on this Mac yet. Open Home in cmux on the Mac to start it.")

    actor Core {
        let client: DaemonClient
        /// Chief's avatar follows the Mac (`chief-profile-changed`).
        private(set) var identity: ChiefIdentity
        private(set) var wire: ChiefWire
        let preferences: ChiefPreferences
        private var conversationID: String?
        private var info: ConversationInfo?
        /// Chief's questions in this conversation (``ChiefQuestionFeed``).
        nonisolated let questionFeed = ChiefQuestionFeed()
        /// Failed turns by message id, with the brain's raw error (``ChiefFailureLog``).
        nonisolated let failureLog = ChiefFailureLog()
        private var continuation: AsyncStream<ConversationBackendEvent>.Continuation?
        private var rev: UInt64 = 0
        private var eventSeq = 0
        private var peerReadSeq = 0
        private var lastSeq = 0
        /// Messages seen, by id: my current tapback (to replace it) and receipts.
        private var known: [String: ConversationMessage] = [:]
        private var readTask: Task<Void, Never>?
        /// Uploaded attachments by the id the store holds, as message parts.
        private var uploadedParts: [String: [String: Any]] = [:]
        /// Attachment bytes by hash: uploaded here or read once with `conversation-attachment-read`.
        private var attachmentBytes: [String: Data] = [:]
        /// 2 MiB: base64 keeps each line under the link's 4 MiB line cap.
        static let chunkBytes = 2 * 1024 * 1024

        init(client: DaemonClient, identity: ChiefIdentity, conversationID: String?, preferences: ChiefPreferences) {
            self.client = client
            self.identity = identity
            self.conversationID = conversationID
            self.preferences = preferences
            wire = ChiefWire(identity: identity)
        }

        // MARK: Requests

        /// Sends one command and returns its `data` object, or throws the
        /// daemon's refusal (`error_code` / reason) as a backend error.
        func call(_ cmd: String, _ params: sending [String: Any] = [:]) async throws -> [String: Any] {
            let line = try await client.request(cmd, params: params)
            guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw ConversationBackendError(code: -32700, message: "bad reply to \(cmd)")
            }
            if reply["ok"] as? Bool == false {
                let error = reply["error"]
                let text = (error as? [String: Any])?["message"] as? String ?? error as? String ?? "\(cmd) failed"
                let code = (error as? [String: Any])?["error_code"] as? String ?? reply["error_code"] as? String
                throw ConversationBackendError(code: -32000, message: code.map { "\($0): \(text)" } ?? text)
            }
            return reply["data"] as? [String: Any] ?? [:]
        }

        /// The Chief conversation: the given id, else the one the Mac's Home
        /// shows. Chief that the Mac has not started yet is an honest error.
        func resolve() async throws -> String {
            if let conversationID { return conversationID }
            let list = try await call("conversation-list")
            guard let id = wire.chiefConversation(in: list["conversations"] as? [[String: Any]] ?? []) else {
                throw ConversationBackendError(code: -2, message: ChiefDaemonBackend.notStarted)
            }
            conversationID = id
            return id
        }

        func updateListState(_ change: ConversationListStateChange) async throws -> ConversationInfo {
            let id = try await resolve()
            if let muted = change.muted { preferences.setMuted(muted, id) }
            if let receipts = change.sendReadReceipts {
                preferences.setSendsReadReceipts(receipts, id)
                // Turning receipts back on reports where this phone has read to.
                if receipts, let lastRead = lastReadHere ?? preferences.readHere(id) { await markRead(lastRead) }
            }
            guard var info = info ?? wire.info(["id": id]) else {
                throw ConversationBackendError(code: -4, message: "no conversation")
            }
            info.listState = preferences.listState(id)
            self.info = info
            return info
        }

        func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage {
            var parts: [[String: Any]] = draft.attachmentIDs.compactMap { uploadedParts[$0] }
            if !draft.text.isEmpty || parts.isEmpty { parts.append(wire.textPart(draft.text, mentions: draft.mentions)) }
            var op: [String: Any] = ["kind": "message.send", "client_msg_id": draft.clientMessageID, "parts": parts]
            if let reply = draft.replyToID { op["reply_to"] = ["message_id": reply, "part_index": 0] }
            return try await self.op(op, idempotencyKey: draft.clientMessageID)
        }

        func upload(_ data: Data, mimeType: String, name: String, width: Int?, height: Int?, file: ConversationFileInfo?) async throws -> ConversationAttachment {
            let id = try await resolve()
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            var begin: [String: Any] = [
                "op": "begin", "conversation": id, "sha256": hash, "byte_count": data.count,
                "mime_type": mimeType, "name": name,
            ]
            if let width, width > 0 { begin["width"] = width }
            if let height, height > 0 { begin["height"] = height }
            let started = try await call("conversation-attachment-upload", begin)
            if let upload = started["upload"] as? String {
                var offset = 0
                repeat {
                    let piece = data.subdata(in: offset..<min(data.count, offset + Self.chunkBytes))
                    _ = try await call("conversation-attachment-upload", [
                        "op": "chunk", "upload": upload, "piece": "original", "offset": offset,
                        "data": piece.base64EncodedString(),
                    ])
                    offset += piece.count
                } while offset < data.count
                _ = try await call("conversation-attachment-upload", ["op": "commit", "upload": upload])
            }
            attachmentBytes[hash] = data
            var part: [String: Any] = [
                "type": "attachment", "hash": hash, "name": name, "mime_type": mimeType, "byte_count": data.count,
            ]
            if let width, width > 0 { part["width"] = width }
            if let height, height > 0 { part["height"] = height }
            let attachment = wire.attachment(part, bytes: data) ?? ConversationAttachment(
                id: "att:\(hash)", kind: .file, width: 0, height: 0, url: nil, localData: data, file: file
            )
            uploadedParts[attachment.id] = part
            return attachment
        }

        /// Reads the bytes of every attachment part not seen yet, so the
        /// message renders from them (the owner serves no URL).
        private func hydrate(_ object: [String: Any]) async {
            guard let id = conversationID else { return }
            for part in object["parts"] as? [[String: Any]] ?? [] where part["type"] as? String == "attachment" {
                guard let hash = part["hash"] as? String, attachmentBytes[hash] == nil else { continue }
                var data = Data()
                var complete = false
                while true {
                    guard let chunk = try? await call("conversation-attachment-read", [
                        "conversation": id, "hash": hash, "offset": data.count, "length": Self.chunkBytes,
                    ]), let text = chunk["data"] as? String, let bytes = Data(base64Encoded: text) else { break }
                    data.append(bytes)
                    if chunk["eof"] as? Bool ?? true || bytes.isEmpty {
                        complete = true
                        break
                    }
                }
                // Only a whole file is kept: a read that failed partway keeps
                // nothing, so the next time the message decodes it reads again
                // (a kept half would draw as a broken image for good).
                if complete, !data.isEmpty { attachmentBytes[hash] = data }
            }
        }

        /// A wire message, its attachments' bytes read first.
        private func decode(_ object: [String: Any]) async -> ConversationMessage? {
            await hydrate(object)
            let asked = ChiefQuestionFeed.questions(in: object)
            questionFeed.update(asked.questions, seq: asked.seq, messageID: object["id"] as? String)
            if let id = object["id"] as? String { failureLog.record(wire.failure(object), messageID: id) }
            return wire.message(object, peerReadSeq: peerReadSeq, bytes: attachmentBytes)
        }

        func op(_ op: sending [String: Any], idempotencyKey: String = UUID().uuidString) async throws -> ConversationMessage {
            try await self.op(op, idempotencyKey: idempotencyKey, expectMessage: true)!
        }

        /// One `conversation-op`; with `expectMessage` the message it made or changed.
        @discardableResult
        func op(_ op: sending [String: Any], idempotencyKey: String = UUID().uuidString, expectMessage: Bool) async throws -> ConversationMessage? {
            let id = try await resolve()
            let result = try await call("conversation-op", ["conversation": id, "idempotency_key": idempotencyKey, "op": op])
            guard expectMessage else { return nil }
            guard let change = result["change"] as? [String: Any], let object = change["message"] as? [String: Any],
                  let message = await decode(object) else {
                throw ConversationBackendError(code: -4, message: "conversation-op returned no message")
            }
            remember(message)
            return message
        }

        func answer(messageID: String, partIndex: Int, answer: JSONValue,
                    signer: any ChiefAnswerSigning) async throws -> ConversationMessage {
            let id = try await resolve()
            let approval = try await signer.approval(conversation: id, messageID: messageID, partIndex: partIndex, answer: answer)
            let answerObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(answer), options: .fragmentsAllowed)
            guard let approvalObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(approval)) as? [String: Any] else {
                throw ConversationBackendError(code: -32602, message: "the approval is not a JSON object")
            }
            let op: [String: Any] = ["kind": "question.answer", "message_id": messageID, "part_index": partIndex, "answer": answerObject]
            let result = try await call("conversation-op", ["conversation": id, "idempotency_key": UUID().uuidString,
                                                            "op": op, "approval": approvalObject])
            guard let change = result["change"] as? [String: Any], let object = change["message"] as? [String: Any],
                  let message = await decode(object) else {
                throw ConversationBackendError(code: -4, message: "conversation-op returned no message")
            }
            remember(message)
            return message
        }

        func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage {
            var latest: ConversationMessage?
            if let current = known[messageID]?.reactions.first(where: { $0.participantID == identity.meID })?.reaction, current != reaction {
                latest = try await op(["kind": "reaction.remove", "message_id": messageID, "part_index": 0, "reaction": wire.wireKind(current)])
            }
            if let reaction, known[messageID]?.reactions.contains(where: { $0.participantID == identity.meID && $0.reaction == reaction }) != true {
                latest = try await op(["kind": "reaction.add", "message_id": messageID, "part_index": 0, "reaction": wire.wireKind(reaction)])
            }
            guard let message = latest ?? known[messageID] else {
                throw ConversationBackendError(code: 404, message: "unknown message")
            }
            return message
        }

        func typing(_ on: Bool) async {
            guard let id = try? await resolve() else { return }
            _ = try? await call("conversation-typing", ["conversation": id, "on": on])
        }

        /// Where this phone has read to, whether or not it told the Mac.
        private var lastReadHere: Int?

        func markRead(_ seq: Int) async {
            guard let id = try? await resolve() else { return }
            lastReadHere = max(lastReadHere ?? preferences.readHere(id) ?? 0, seq)
            // Send Read Receipts off: the read position stays on this phone
            // (kept, so a new backend after a reconnect still knows it).
            guard preferences.sendsReadReceipts(id) else {
                if let lastReadHere, preferences.readHere(id) != lastReadHere { preferences.setReadHere(lastReadHere, id) }
                yieldReadState(lastRead: seq)
                return
            }
            _ = try? await call("conversation-op", [
                "conversation": id, "idempotency_key": UUID().uuidString, "op": ["kind": "read_cursor.set", "seq": seq],
            ])
            yieldReadState(lastRead: seq)
        }

        func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
            let id = try await resolve()
            let objects: [[String: Any]]
            if let beforeSeq {
                let page = try await call("conversation-history", ["conversation": id, "before_seq": beforeSeq, "limit": min(500, max(1, limit))])
                objects = page["messages"] as? [[String: Any]] ?? []
            } else {
                let snapshot = try await call("conversation-snapshot", ["conversation": id, "tail": min(500, max(1, limit))])
                // Not the event cursor: this page goes to whoever asked (a
                // resync, a test, not always the store) and covers only its
                // tail, so an event the snapshot already counted must still
                // be applied when it lands. Only `connect` moves `rev` off a
                // snapshot, and its `.connected` makes the store refetch.
                if let summary = snapshot["conversation"] as? [String: Any] { absorb(summary, movingRev: false) }
                objects = snapshot["messages"] as? [[String: Any]] ?? []
            }
            var messages: [ConversationMessage] = []
            for object in objects {
                if let message = await decode(object) { messages.append(message) }
            }
            messages.forEach(remember)
            return ConversationHistoryPage(messages: messages, hasMore: (messages.first?.seq ?? 1) > 1)
        }

        // MARK: Session

        func run(_ continuation: AsyncStream<ConversationBackendEvent>.Continuation) async {
            self.continuation = continuation
            do {
                let id = try await resolve()
                _ = try await call("subscribe")
                try await connect(id: id, lagged: false)
            } catch {
                continuation.yield(.disconnected(reason: (error as? ConversationBackendError)?.message ?? "\(error)"))
                return
            }
            for await line in client.events {
                await route(line)
            }
            continuation.yield(.disconnected(reason: "daemon channel closed"))
        }

        private func connect(id: String, lagged: Bool) async throws {
            let snapshot = try await call("conversation-snapshot", ["conversation": id, "tail": 1])
            guard let summary = snapshot["conversation"] as? [String: Any], var info = wire.info(summary) else {
                throw ConversationBackendError(code: -4, message: "conversation-snapshot returned no conversation")
            }
            info.listState = preferences.listState(id)
            self.info = info
            absorb(summary)
            continuation?.yield(.connected(info: info, meID: identity.meID, lagged: lagged))
            // With receipts off the Mac's cursor lags what this phone read.
            let server = wire.readCursor(summary, of: identity.meID)
            let here = lastReadHere ?? preferences.readHere(id) ?? 0
            yieldReadState(lastRead: preferences.sendsReadReceipts(id) ? server : max(server, here))
        }

        /// Takes a conversation summary's counters. `movingRev` advances the
        /// live-event cursor too, so events up to that `rev` are dropped as
        /// already seen: right only when the store refetches from it.
        private func absorb(_ summary: [String: Any], movingRev: Bool = true) {
            if movingRev { rev = max(rev, (summary["rev"] as? NSNumber)?.uint64Value ?? 0) }
            lastSeq = max(lastSeq, (summary["last_seq"] as? NSNumber)?.intValue ?? 0)
            peerReadSeq = max(peerReadSeq, wire.readCursor(summary, of: identity.chiefID))
        }

        private func yieldReadState(lastRead: Int) {
            let unread = known.values.filter { ($0.seq ?? 0) > lastRead && $0.senderID != identity.meID }.count
            continuation?.yield(.readState(ConversationReadState(lastReadSeq: lastRead, unreadCount: unread, headSeq: lastSeq)))
        }

        private func remember(_ message: ConversationMessage) {
            known[message.id] = message
            lastSeq = max(lastSeq, message.seq ?? 0)
        }

        private func yieldMessage(_ message: ConversationMessage) {
            remember(message)
            eventSeq += 1
            continuation?.yield(.message(message, eventSeq: eventSeq))
        }

        /// Fetches the conversation again (after an unconfirmed answer):
        /// the store refetches the newest page, and the question feed hears
        /// whether the Mac has the answer.
        func resync() async throws {
            let id = try await resolve()
            try await connect(id: id, lagged: true)
            // Read the newest page here too, so the feed is settled when this returns.
            _ = try await history(beforeSeq: nil, limit: 50)
        }

        /// Draws Chief with `text` (nil: the default "C") from now on, and
        /// tells the store, so the header and every avatar change in place.
        func applyAvatar(_ text: String?) {
            let avatar = text ?? ChiefIdentity.defaultAvatar
            guard avatar != identity.avatar else { return }
            identity.avatar = avatar
            wire = ChiefWire(identity: identity)
            guard var info else { return }
            info.participants = info.participants.map { participant in
                guard participant.id == identity.chiefID else { return participant }
                var changed = participant
                changed.initials = avatar
                return changed
            }
            self.info = info
            continuation?.yield(.conversationChanged(info))
        }

        func route(_ line: Data) async {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let event = object["event"] as? String else { return }
            // The Mac's Chief Settings changed the avatar (capability
            // chief-profile-events-v1): no conversation, only the text.
            if event == ChiefDaemonBackend.profileEvent {
                // Only an explicit `avatar` changes it: null clears it (a
                // picture, or none); a profile event about something else
                // (no key) leaves Chief as drawn (R2-6).
                if object.keys.contains("avatar") {
                    applyAvatar(ChiefEngineReport.avatarText(object["avatar"] as? String))
                }
                return
            }
            guard object["conversation"] as? String == conversationID else { return }
            switch event {
            case "conversation-typing":
                guard let who = object["participant"] as? String, who != identity.meID else { return }
                continuation?.yield(.typing(participantID: who, isTyping: object["on"] as? Bool ?? false))
            case "conversation-changed":
                let incoming = (object["rev"] as? NSNumber)?.uint64Value ?? 0
                guard incoming > rev else { return }
                if incoming > rev + 1, let id = conversationID {
                    // Missed ops: resync, and the store refetches the newest page.
                    // The snapshot sets `rev`; if it fails, the next event finds
                    // the same gap and tries again (moving `rev` first lost the
                    // missed messages until some later gap).
                    try? await connect(id: id, lagged: true)
                    return
                }
                rev = incoming
                await apply(object["change"] as? [String: Any] ?? [:])
            default:
                break
            }
        }

        private func apply(_ change: [String: Any]) async {
            switch change["kind"] as? String {
            case "message", "message-updated":
                if let object = change["message"] as? [String: Any], let message = await decode(object) {
                    yieldMessage(message)
                }
            case "read-cursor":
                let seq = (change["seq"] as? NSNumber)?.intValue ?? 0
                guard let who = change["participant"] as? String else { return }
                if who == identity.meID {
                    yieldReadState(lastRead: seq)
                } else if who == identity.chiefID, seq > peerReadSeq {
                    let previous = peerReadSeq
                    peerReadSeq = seq
                    // Receipts: my messages Chief just read.
                    for var message in known.values.sorted(by: { ($0.seq ?? 0) < ($1.seq ?? 0) })
                    where message.senderID == identity.meID && (message.seq ?? 0) > previous && (message.seq ?? 0) <= seq {
                        message.delivery = .read(Date())
                        yieldMessage(message)
                    }
                }
            case "conversation":
                if let summary = change["conversation"] as? [String: Any], var info = wire.info(summary) {
                    info.listState = preferences.listState(info.id)
                    self.info = info
                    absorb(summary)
                    continuation?.yield(.conversationChanged(info))
                }
            default:
                break
            }
        }

        /// Ends the event stream and the daemon channel under it: without the
        /// channel's close its read loop and the Mac's connection stayed up
        /// for every conversation screen Home replaced.
        func close() async {
            continuation?.finish()
            continuation = nil
            await client.close()
        }
    }
}

/// Signs one Chief question answer with the iPhone's approval key after Face ID
/// (CmuxMobileLive `ChiefAnswerSigner`, cmux-mobile-host `chief_answers.rs`).
public protocol ChiefAnswerSigning: Sendable {
    /// `{approver, nonce, expiresAt, signature}` for this exact answer.
    func approval(conversation: String, messageID: String, partIndex: Int, answer: JSONValue) async throws -> JSONValue
}
