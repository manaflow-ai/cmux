import CmuxConversationCore
import Foundation

/// The Cloud Chief: the main conversation of the user's Cloud Chief, held by
/// the Cloud service (one ConversationDO per conversation) and answered by
/// the Chief's Cloud brain (or a server the chief is placed on).
///
/// Wire (backend `index.ts`, `owner-do.ts`, `conversation-do.ts`,
/// `conversation-live.ts`; the Mac daemon's `cmux-tui-cloud-conversations`):
/// - Socket `GET /v1/wire/conv/<conversation>`, subprotocol `cmux.wire.v1`,
///   `authorization: Bearer <access token>`. The owner says `welcome`
///   (`principal.user`, `capabilities: ["chief-live-v1"]`); the phone sends
///   `subscribe` (with `after_seq` on a resume), then gets a `snapshot`
///   (`seq`, `state` = the head) or the missed `event` frames, one `run.live`,
///   and from then on `event` (`seq`, `op`, `effects {state, writes}`),
///   `conversation-typing`, `conversation-run-changed`, `step.delta`,
///   `run.activity` and `run.live`. A `seq` gap asks `snapshot.request`; a live
///   gap asks `run.live.get`. The phone sends `typing {on}` on the socket.
/// - Reads `POST /v1/read {op, params}`: `conversation.snapshot {conversation, tail}`
///   (newest page) and `conversation.history {conversation, before_seq, limit}`.
/// - Writes `POST /v1/ops {op, params: {conversation, ...}, idempotency_key, origin}`:
///   `message.send`, `message.edit`, `message.retract`, `reaction.add`,
///   `reaction.remove`, `read_cursor.set`. Messages use the local owner's JSON
///   (``ChiefWire``), which the Cloud shares.
public final class ChiefCloudBackend: ConversationBackend, ChiefLiveSource, @unchecked Sendable {
    let core: Core
    public let liveFeed: ChiefLiveFeed

    /// `refused` runs once if the service refuses the conversation itself
    /// (the socket upgrade or the subscribe): the backend stops dialing.
    init(http: ChiefCloudHTTP, conversationID: String, identity: ChiefIdentity,
         preferences: ChiefPreferences, clock: any Clock<Duration> = ContinuousClock(),
         refused: @escaping @Sendable (String) -> Void = { _ in }) {
        let feed = ChiefLiveFeed()
        liveFeed = feed
        core = Core(http: http, conversationID: conversationID, identity: identity, preferences: preferences,
                    clock: clock, liveFeed: feed, refused: refused)
    }

    /// The conversation this backend talks to.
    public var conversationID: String { core.conversationID }

    public func events() -> AsyncStream<ConversationBackendEvent> {
        let (stream, continuation) = AsyncStream<ConversationBackendEvent>.makeStream(bufferingPolicy: .unbounded)
        Task { await core.start(continuation) }
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

    public func edit(messageID: String, text: String) async throws -> ConversationMessage {
        try await core.messageOp("message.edit", ["message_id": messageID, "parts": [["type": "text", "text": text]]])
    }

    public func unsend(messageID: String) async throws -> ConversationMessage {
        try await core.messageOp("message.retract", ["message_id": messageID])
    }

    public func setTyping(_ isTyping: Bool) async {
        await core.typing(isTyping)
    }

    public func markRead(upToSeq: Int) async {
        await core.markRead(upToSeq)
    }

    /// Cloud attachments need the upload slot flow (`/v1/home/attachments`),
    /// which the phone does not speak yet.
    public func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment {
        throw ConversationBackendError(code: -32601, message: String(localized: "Photos can't be sent to Cloud Chief from iPhone yet."))
    }

    /// Hide Alerts and Send Read Receipts belong to this phone (``ChiefPreferences``).
    public func updateListState(_ change: ConversationListStateChange) async throws -> ConversationInfo {
        try await core.updateListState(change)
    }

    public func close() {
        Task { await core.close() }
    }

    /// The app came back to the foreground or the network changed: a live
    /// socket is pinged now (a dead one is closed and dialed again), and a
    /// wait between dials ends at once.
    public func reconnectNow() {
        Task { await core.nudge() }
    }

    actor Core {
        let http: ChiefCloudHTTP
        nonisolated let conversationID: String
        private(set) var identity: ChiefIdentity
        private var wire: ChiefWire
        let preferences: ChiefPreferences
        let clock: any Clock<Duration>
        nonisolated let liveFeed: ChiefLiveFeed
        let refused: @Sendable (String) -> Void
        private var live: ChiefLiveState
        /// The subscribe is the newest frame this socket sent and nothing
        /// answered it yet: an auth error now refuses the subscription, not
        /// a later frame (a typing or `run.live.get` refusal is not fatal).
        private var subscribeOutstanding = false
        /// A `run.live.get` is out; another gap waits for its answer.
        private var liveResyncPending = false

        private var continuation: AsyncStream<ConversationBackendEvent>.Continuation?
        private var runner: Task<Void, Never>?
        private var socket: URLSessionWebSocketTask?
        private var closed = false
        /// The wait between dials (``nudge()`` cancels it).
        private var backoff: Task<Void, Never>?
        /// A nudge came: the next dial starts the backoff from the start.
        private var nudged = false
        /// The ping ``nudge()`` sent and nothing answered yet.
        private var nudgePing: UUID?
        private var info: ConversationInfo?
        /// The last stream seq applied (snapshot or event); a resume starts after it.
        private var streamSeq: Int?
        private var awaitingSnapshot = false
        /// The principal of the last `welcome`: another one drops `streamSeq`.
        private var principalUser: String?
        private var everConnected = false
        private var eventSeq = 0
        private var peerReadSeq = 0
        private var lastSeq = 0
        private var lastReadHere: Int?
        /// Messages seen, by id: my current tapback (to replace it) and receipts.
        private var known: [String: ConversationMessage] = [:]

        init(http: ChiefCloudHTTP, conversationID: String, identity: ChiefIdentity, preferences: ChiefPreferences,
             clock: any Clock<Duration>, liveFeed: ChiefLiveFeed, refused: @escaping @Sendable (String) -> Void) {
            self.refused = refused
            self.http = http
            self.conversationID = conversationID
            self.identity = identity
            self.preferences = preferences
            self.clock = clock
            self.liveFeed = liveFeed
            wire = ChiefWire(identity: identity)
            live = ChiefLiveState(conversation: conversationID)
        }

        private var stream: String { "conv:\(conversationID)" }

        static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

        // MARK: Requests

        func read(_ op: String, _ params: [String: Any]) async throws -> [String: Any] {
            let body = try ChiefCloudHTTP.json(["op": op, "params": params])
            let reply = try await http.send("POST", "/v1/read", body: body)
            guard let value = try ChiefCloudHTTP.value(reply) as? [String: Any] else {
                throw ConversationBackendError(code: -32700, message: "\(op) returned no value")
            }
            return value
        }

        /// One conversation op; returns its value (`{rev, seq, change}`).
        @discardableResult
        func op(_ kind: String, _ fields: [String: Any], key: String = UUID().uuidString) async throws -> [String: Any] {
            var params = fields
            params["conversation"] = conversationID
            let body = try ChiefCloudHTTP.json(["op": kind, "params": params, "idempotency_key": key, "origin": "user"])
            let reply = try await http.send("POST", "/v1/ops", body: body)
            do {
                return try ChiefCloudHTTP.value(reply) as? [String: Any] ?? [:]
            } catch let error as ChiefCloudError {
                throw ConversationBackendError(code: -32000, message: error.description)
            }
        }

        /// An op that makes or changes a message, and that message.
        func messageOp(_ kind: String, _ fields: sending [String: Any], key: String = UUID().uuidString) async throws -> ConversationMessage {
            let value = try await op(kind, fields, key: key)
            let object = (value["change"] as? [String: Any])?["message"] as? [String: Any] ?? value["message"] as? [String: Any]
            guard let object, let message = wire.message(object, peerReadSeq: peerReadSeq) else {
                throw ConversationBackendError(code: -4, message: "\(kind) returned no message")
            }
            remember(message)
            return message
        }

        func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage {
            var fields: [String: Any] = [
                "client_msg_id": draft.clientMessageID,
                "parts": [wire.textPart(draft.text, mentions: draft.mentions)],
            ]
            if let reply = draft.replyToID { fields["reply_to"] = ["message_id": reply, "part_index": 0] }
            let message = try await messageOp("message.send", fields, key: draft.clientMessageID)
            // Committed: Chief's answer is on its way (the typing indicator shows).
            updateLive(live.sent(seq: message.seq))
            return message
        }

        func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage {
            var latest: ConversationMessage?
            if let current = known[messageID]?.reactions.first(where: { $0.participantID == identity.meID })?.reaction, current != reaction {
                latest = try await messageOp("reaction.remove", ["message_id": messageID, "part_index": 0, "reaction": wire.wireKind(current)])
            }
            if let reaction, known[messageID]?.reactions.contains(where: { $0.participantID == identity.meID && $0.reaction == reaction }) != true {
                latest = try await messageOp("reaction.add", ["message_id": messageID, "part_index": 0, "reaction": wire.wireKind(reaction)])
            }
            guard let message = latest ?? known[messageID] else {
                throw ConversationBackendError(code: 404, message: "unknown message")
            }
            return message
        }

        func typing(_ on: Bool) async {
            guard let socket else { return }
            guard let text = try? Self.text(["t": "typing", "on": on]) else { return }
            subscribeOutstanding = false
            try? await Self.send(text, on: socket)
        }

        func markRead(_ seq: Int) async {
            lastReadHere = max(lastReadHere ?? preferences.readHere(conversationID) ?? 0, seq)
            // Send Read Receipts off: the read position stays on this phone
            // (kept, so a reconnect or relaunch still knows it).
            if preferences.sendsReadReceipts(conversationID) {
                _ = try? await op("read_cursor.set", ["seq": seq])
            } else if let lastReadHere, preferences.readHere(conversationID) != lastReadHere {
                preferences.setReadHere(lastReadHere, conversationID)
            }
            yieldReadState(lastRead: seq)
        }

        func updateListState(_ change: ConversationListStateChange) async throws -> ConversationInfo {
            if let muted = change.muted { preferences.setMuted(muted, conversationID) }
            if let receipts = change.sendReadReceipts {
                preferences.setSendsReadReceipts(receipts, conversationID)
                // Turning receipts back on reports where this phone has read to.
                if receipts, let lastRead = lastReadHere ?? preferences.readHere(conversationID) { await markRead(lastRead) }
            }
            guard var info = info ?? wire.info(["id": conversationID]) else {
                throw ConversationBackendError(code: -4, message: "no conversation")
            }
            info.listState = preferences.listState(conversationID)
            self.info = info
            return info
        }

        func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
            var objects: [[String: Any]]
            var hasMore: Bool?
            if let beforeSeq {
                let page = try await read("conversation.history", [
                    "conversation": conversationID, "before_seq": beforeSeq, "limit": min(200, max(1, limit)),
                ])
                objects = page["messages"] as? [[String: Any]] ?? []
                hasMore = page["has_more"] as? Bool
            } else {
                let snapshot = try await read("conversation.snapshot", ["conversation": conversationID, "tail": min(50, max(1, limit))])
                // Counters only: the live cursor moves with the socket.
                if let head = snapshot["state"] as? [String: Any] { absorb(head, peer: true) }
                let rows = snapshot["rows"] as? [String: Any]
                objects = (rows?["table"] as? String ?? "msg") == "msg"
                    ? (rows?["rows"] as? [[String: Any]] ?? []).compactMap { $0["row"] as? [String: Any] } : []
            }
            objects.sort { (Self.int($0["seq"]) ?? 0) < (Self.int($1["seq"]) ?? 0) }
            let messages = objects.compactMap { wire.message($0, peerReadSeq: peerReadSeq) }
            messages.forEach(remember)
            return ConversationHistoryPage(messages: messages, hasMore: hasMore ?? ((messages.first?.seq ?? 1) > 1))
        }

        // MARK: Socket

        func start(_ continuation: AsyncStream<ConversationBackendEvent>.Continuation) {
            guard runner == nil, !closed else { return }
            self.continuation = continuation
            runner = Task { await self.loop() }
        }

        func close() {
            closed = true
            runner?.cancel()
            runner = nil
            socket?.cancel(with: .goingAway, reason: nil)
            socket = nil
            backoff?.cancel()
            backoff = nil
            liveFeed.update(nil)
            continuation?.finish()
            continuation = nil
        }

        /// Why a socket ended.
        private enum SocketEnd {
            case ended(welcomed: Bool, unauthorized: Bool, reason: String)
            case refused(String)
        }

        private struct Refused: Error {
            let reason: String
        }

        /// Waits after the `attempt`th failure in a row: 1, 2, 4, 8, 16, then every 30 s.
        static func retryDelay(attempt: Int) -> Duration {
            attempt >= 5 ? .seconds(30) : .seconds(1 << max(0, attempt))
        }

        private func loop() async {
            var attempt = 0
            var forceRefresh = false
            while !closed, !Task.isCancelled {
                let end = await connectOnce(forceRefresh: forceRefresh)
                guard !closed, !Task.isCancelled else { return }
                resetLive()
                switch end {
                case let .refused(reason):
                    continuation?.yield(.disconnected(reason: reason))
                    refused(reason)
                    return
                case let .ended(welcomed, unauthorized, reason):
                    if welcomed { attempt = 0 }
                    forceRefresh = unauthorized
                    continuation?.yield(.disconnected(reason: reason))
                }
                if nudged {
                    // The nudge closed a dead socket: dial again now.
                    nudged = false
                    attempt = 0
                    continue
                }
                let delay = Self.retryDelay(attempt: attempt)
                let clock = clock
                let wait = Task { _ = try? await clock.sleep(for: delay) }
                backoff = wait
                await wait.value
                backoff = nil
                guard !Task.isCancelled else { return }
                if nudged {
                    // Dial now, and wait from the start after a failure.
                    nudged = false
                    attempt = 0
                } else {
                    attempt += 1
                }
            }
        }

        /// Foreground or a network change: ping the socket now (no answer
        /// closes it, and the loop dials again), or end the wait between dials.
        func nudge() async {
            guard !closed else { return }
            if let backoff {
                nudged = true
                backoff.cancel()
                return
            }
            guard let socket else { return }
            // A socket the network dropped may never answer: 5 s is the limit.
            let token = UUID()
            nudgePing = token
            let clock = clock
            let timer = Task { [weak self] in
                guard (try? await clock.sleep(for: .seconds(5))) != nil else { return }
                await self?.nudgePingEnded(token, socket, answered: false)
            }
            let answered = await Self.ping(socket)
            timer.cancel()
            nudgePingEnded(token, socket, answered: answered)
        }

        private func nudgePingEnded(_ token: UUID, _ socket: URLSessionWebSocketTask, answered: Bool) {
            guard nudgePing == token else { return }
            nudgePing = nil
            guard !answered else { return }
            nudged = true
            socket.cancel(with: .goingAway, reason: nil)
        }

        private func socketURL() -> URL? {
            guard var components = URLComponents(url: http.base, resolvingAgainstBaseURL: false) else { return nil }
            components.scheme = components.scheme == "http" ? "ws" : "wss"
            components.path = "/v1/wire/conv/\(conversationID)"
            components.query = nil
            return components.url
        }

        private func connectOnce(forceRefresh: Bool) async -> SocketEnd {
            guard let url = socketURL() else { return .refused("bad Cloud address") }
            let token: String
            do {
                token = try await http.token(forceRefresh: forceRefresh)
            } catch {
                return .ended(welcomed: false, unauthorized: false, reason: "no access token: \(error)")
            }
            // Closed while the token came: open nothing.
            guard !closed, !Task.isCancelled else { return .ended(welcomed: false, unauthorized: false, reason: "closed") }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
            request.setValue("cmux.wire.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
            let task = http.session.webSocketTask(with: request)
            socket = task
            awaitingSnapshot = false
            subscribeOutstanding = false
            task.resume()
            let pinger = Task { await self.keepAlive(task) }
            // Every exit closes this socket (a no-op on one already closed).
            defer {
                pinger.cancel()
                task.cancel(with: .goingAway, reason: nil)
                if socket === task { socket = nil }
            }
            var welcomed = false
            do {
                while !closed, !Task.isCancelled {
                    guard let text = try await Self.receive(task) else { continue }
                    if try await handle(text, on: task) { welcomed = true }
                }
                return .ended(welcomed: welcomed, unauthorized: false, reason: "closed")
            } catch let refusal as Refused {
                return .refused(refusal.reason)
            } catch {
                let status = (task.response as? HTTPURLResponse)?.statusCode
                // The upgrade itself was refused: not a member, or no such conversation.
                if !welcomed, status == 403 || status == 404 {
                    return .refused("the service refused the conversation (HTTP \(status ?? 0))")
                }
                // 4401: the owner closed the socket because the token expired.
                let expired = task.closeCode.rawValue == 4401
                return .ended(welcomed: welcomed, unauthorized: status == 401 || expired, reason: "socket ended: \(error.localizedDescription)")
            }
        }

        /// Pings every 25 s; a socket that stops answering is closed, so the loop dials again.
        private func keepAlive(_ task: URLSessionWebSocketTask) async {
            while !Task.isCancelled {
                do { try await clock.sleep(for: .seconds(25)) } catch { return }
                guard await Self.ping(task) else {
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }

        static func receive(_ task: URLSessionWebSocketTask) async throws -> String? {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, any Error>) in
                task.receive { result in
                    switch result {
                    case let .success(.string(text)): continuation.resume(returning: text)
                    case let .success(.data(data)): continuation.resume(returning: String(data: data, encoding: .utf8))
                    case .success: continuation.resume(returning: nil)
                    case let .failure(error): continuation.resume(throwing: error)
                    }
                }
            }
        }

        static func send(_ text: String, on task: URLSessionWebSocketTask) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                task.send(.string(text)) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }

        static func ping(_ task: URLSessionWebSocketTask) async -> Bool {
            await ping(using: task.sendPing)
        }

        /// One protocol ping through `sendPing`; true when the pong came back.
        /// URLSession can call the pong handler more than once while the
        /// socket tears down, so only the first call resumes.
        static func ping(using sendPing: (@escaping @Sendable ((any Error)?) -> Void) -> Void) async -> Bool {
            let once = PongOnce()
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                sendPing { error in
                    if once.claim() { continuation.resume(returning: error == nil) }
                }
            }
        }

        static func text(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }

        private func frame(_ object: [String: Any], on task: URLSessionWebSocketTask) async throws {
            try await Self.send(try Self.text(object), on: task)
        }

        /// One frame from the owner; true for `welcome`.
        private func handle(_ text: String, on task: URLSessionWebSocketTask) async throws -> Bool {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            switch (object["t"] as? String) ?? (object["type"] as? String) ?? "" {
            case "welcome":
                try await welcome(object, on: task)
                return true
            case "snapshot":
                snapshot(object)
            case "event":
                try await event(object, on: task)
            case "conversation-typing":
                guard object["conversation"] as? String == conversationID,
                      let who = object["participant"] as? String, who != identity.meID else { return false }
                let on = object["on"] as? Bool ?? false
                // Chief's typing is the live status line (one indicator, not
                // also the transcript's typing bubble); anyone else's is the store's.
                if who == identity.chiefID {
                    updateLive(live.typing(on, author: who))
                } else {
                    continuation?.yield(.typing(participantID: who, isTyping: on))
                }
            case "conversation-run-changed":
                try await applyLive(live.runChanged(object), on: task)
            case "step.delta":
                try await applyLive(live.delta(object), on: task)
            case "run.activity":
                try await applyLive(live.activity(object), on: task)
            case "run.live":
                liveResyncPending = false
                // The owner sends one after a subscribe: the subscribe was taken.
                subscribeOutstanding = false
                try await applyLive(live.snapshot(object), on: task)
            case "error":
                // Only a refused subscribe ends the socket for good; an error
                // that answers a typing or `run.live.get` frame is dropped.
                let code = object["code"] as? String ?? ""
                // A refused `run.live.get` must not stop later gaps from resyncing.
                liveResyncPending = false
                if subscribeOutstanding, code == "auth.forbidden" || code == "auth.unauthenticated" {
                    throw Refused(reason: object["message"] as? String ?? code)
                }
            default:
                break
            }
            return false
        }

        private func welcome(_ object: [String: Any], on task: URLSessionWebSocketTask) async throws {
            let user = ((object["principal"] as? [String: Any])?["user"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let user {
                // Another account: never resume its position.
                if principalUser != user { streamSeq = nil }
                principalUser = user
                let me = user.hasPrefix("user_") ? user : "user_\(user)"
                if me != identity.meID {
                    identity.meID = me
                    wire = ChiefWire(identity: identity)
                }
            } else {
                streamSeq = nil
                principalUser = nil
            }
            var subscribe: [String: Any] = ["t": "subscribe"]
            if let streamSeq { subscribe["after_seq"] = streamSeq }
            try await frame(subscribe, on: task)
            subscribeOutstanding = true
            // A resume: the owner replays what was missed (or sends a
            // snapshot, which reconnects with a refetch); nothing missed
            // sends nothing, so the conversation is live now.
            if streamSeq != nil, let info {
                continuation?.yield(.connected(info: info, meID: identity.meID, lagged: false))
            }
        }

        private func snapshot(_ object: [String: Any]) {
            if let named = object["stream"] as? String, named != stream { return }
            guard let seq = Self.int(object["seq"]), let head = object["state"] as? [String: Any],
                  var info = wire.info(head) else { return }
            awaitingSnapshot = false
            subscribeOutstanding = false
            streamSeq = seq
            info.listState = preferences.listState(conversationID)
            self.info = info
            absorb(head, peer: false)
            let lagged = everConnected
            everConnected = true
            continuation?.yield(.connected(info: info, meID: identity.meID, lagged: lagged))
            takeChiefCursor(head)
            // With receipts off the service's cursor lags what this phone read.
            let server = wire.readCursor(head, of: identity.meID)
            let here = lastReadHere ?? preferences.readHere(conversationID) ?? 0
            yieldReadState(lastRead: preferences.sendsReadReceipts(conversationID) ? server : max(server, here))
        }

        private func requestSnapshot(on task: URLSessionWebSocketTask) async throws {
            guard !awaitingSnapshot else { return }
            awaitingSnapshot = true
            subscribeOutstanding = false
            try await frame(["t": "snapshot.request"], on: task)
        }

        private func event(_ object: [String: Any], on task: URLSessionWebSocketTask) async throws {
            if let named = object["stream"] as? String, named != stream { return }
            guard !awaitingSnapshot, let seq = Self.int(object["seq"]), let last = streamSeq, seq > last else { return }
            subscribeOutstanding = false
            guard seq == last + 1, apply(object) else {
                try await requestSnapshot(on: task)
                return
            }
            streamSeq = seq
        }

        /// One committed op as store events (the Mac daemon's `conversation_change`);
        /// false when the frame carries nothing to map (the caller resyncs).
        private func apply(_ object: [String: Any]) -> Bool {
            guard let op = object["op"] as? String, !op.hasPrefix("conversation.import"),
                  let effects = object["effects"] as? [String: Any], let head = effects["state"] as? [String: Any] else { return false }
            absorb(head, peer: false)
            // Every head carries Chief's read cursor: receipts move with any op.
            takeChiefCursor(head)
            let rows = (effects["writes"] as? [[String: Any]] ?? [])
                .filter { $0["table"] as? String == "msg" && $0["op"] as? String == "upsert" }
                .compactMap { $0["row"] as? [String: Any] }
            if !rows.isEmpty {
                for row in rows {
                    if let message = wire.message(row, peerReadSeq: peerReadSeq) { yieldMessage(message) }
                }
            } else if op == "read_cursor.set" {
                guard let who = Self.participant(object["actor"]) else { return false }
                let seq = Self.int((head["read_cursors"] as? [String: Any])?[who])
                    ?? Self.int((object["params"] as? [String: Any])?["seq"])
                guard let seq else { return false }
                readCursor(who, seq: seq)
            } else if var info = wire.info(head) {
                info.listState = preferences.listState(conversationID)
                self.info = info
                continuation?.yield(.conversationChanged(info))
            }
            return true
        }

        /// The participant id of an event's actor (home-core `actorOf`).
        static func participant(_ value: Any?) -> String? {
            guard let principal = value as? [String: Any] else { return nil }
            if let agent = principal["agent"] as? String { return agent.hasPrefix("agent_") ? agent : "agent_\(agent)" }
            if let user = principal["user"] as? String { return user.hasPrefix("user_") ? user : "user_\(user)" }
            return nil
        }

        private func readCursor(_ who: String, seq: Int) {
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
        }

        // MARK: Live frames

        private func applyLive(_ outcome: ChiefLiveState.Outcome, on task: URLSessionWebSocketTask) async throws {
            if outcome != .ignored { liveFeed.update(live.current) }
            guard outcome == .resync, !liveResyncPending else { return }
            liveResyncPending = true
            subscribeOutstanding = false
            try await frame(["t": "run.live.get", "type": "run.live.get", "conversation": conversationID], on: task)
        }

        /// A live change that needs no answer from the owner.
        private func updateLive(_ outcome: ChiefLiveState.Outcome) {
            if outcome != .ignored { liveFeed.update(live.current) }
        }

        /// A new socket starts empty: the owner's `run.live` brings back the
        /// runs that are live, but not a wait for a run that has not begun.
        private func resetLive() {
            live = ChiefLiveState(conversation: conversationID)
            liveResyncPending = false
            liveFeed.update(nil)
        }

        // MARK: State

        /// Takes a head's counters; `peer` also takes Chief's read cursor
        /// (a snapshot), where an event leaves it to ``readCursor(_:seq:)``.
        private func absorb(_ head: [String: Any], peer: Bool) {
            lastSeq = max(lastSeq, Self.int(head["last_seq"]) ?? 0)
            if peer { peerReadSeq = max(peerReadSeq, wire.readCursor(head, of: identity.chiefID)) }
        }

        /// Chief's read cursor from a head: my messages it covers read as Read.
        private func takeChiefCursor(_ head: [String: Any]) {
            readCursor(identity.chiefID, seq: wire.readCursor(head, of: identity.chiefID))
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
            if message.senderID == identity.chiefID { updateLive(live.chiefMessage(seq: message.seq)) }
            remember(message)
            eventSeq += 1
            continuation?.yield(.message(message, eventSeq: eventSeq))
        }
    }
}
