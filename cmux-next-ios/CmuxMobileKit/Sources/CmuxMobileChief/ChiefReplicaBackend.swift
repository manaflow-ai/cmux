import CmuxConversationCore
import Foundation

/// The Mac Chief while the Mac is offline or asleep: its cloud copy
/// (cmux-prompts logs/iphone-chief-DESIGN.md, a450).
///
/// The Mac's daemon publishes the Home Chief conversation and its newest
/// messages on `host:<h>/chief` of its read replica (backend
/// `host-replica/wire.ts`, cmux-tui `cloud_host_replica.rs`). This backend
/// reads that copy over `GET /v1/wire/host/<host>` (`cmux.wire.v1`, the
/// signed-in session's bearer) and sends text with
/// `op conversation.message.send`. With the Mac offline the Cloud service
/// keeps the message (`op.queued`) and hands it to the Mac when it is back,
/// under the same key, so it arrives once. With the Mac online the same op
/// runs at once.
public final class ChiefReplicaBackend: ConversationBackend, @unchecked Sendable {
    let core: Core

    /// `host`: the Mac's `host_` id in the team directory.
    init(http: ChiefCloudHTTP, host: String, identity: ChiefIdentity = .standard) {
        core = Core(http: http, host: host, identity: identity)
    }

    /// The Mac's host id this backend reads.
    public var host: String { core.host }

    public func events() -> AsyncStream<ConversationBackendEvent> {
        let (stream, continuation) = AsyncStream<ConversationBackendEvent>.makeStream(bufferingPolicy: .unbounded)
        Task { await core.start(continuation) }
        return stream
    }

    public func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
        await core.history(beforeSeq: beforeSeq, limit: limit)
    }

    public func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage {
        try await core.send(draft)
    }

    /// The newest messages of the copy, oldest first (the Cloud Chief hand-off quotes them).
    public func recentMessages(_ count: Int) async -> [ConversationMessage] {
        await core.recent(count)
    }

    private var unsupported: ConversationBackendError {
        ConversationBackendError(code: -32601, message: String(localized: "Your Mac is offline. Only text can wait for it."))
    }

    public func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage { throw unsupported }
    public func edit(messageID: String, text: String) async throws -> ConversationMessage { throw unsupported }
    public func unsend(messageID: String) async throws -> ConversationMessage { throw unsupported }
    public func setTyping(_ isTyping: Bool) async {}
    public func markRead(upToSeq: Int) async {}
    public func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment { throw unsupported }

    public func close() {
        Task { await core.close() }
    }

    static let cloudKeyPrefix = "cloud-"

    /// One copy as the replica stores it: the conversation summary and its newest messages.
    struct Copy {
        var info: ConversationInfo
        var messages: [ConversationMessage]

        /// Decodes a `snapshot` frame's `state` (`{conversation, messages}`); nil for anything else.
        static func decode(_ state: [String: Any], wire: ChiefWire) -> Copy? {
            guard let summary = state["conversation"] as? [String: Any], let info = wire.info(summary) else { return nil }
            let cursor = wire.readCursor(summary, of: wire.identity.chiefID)
            let messages = (state["messages"] as? [[String: Any]] ?? []).compactMap { object -> ConversationMessage? in
                guard var message = wire.message(object, peerReadSeq: cursor) else { return nil }
                // A message this phone sent through the cloud carries `cloud-<its key>` (cmux-tui
                // cloud_host_replica.rs): the bare key names the phone's pending row.
                if let id = message.clientMessageID, id.hasPrefix(ChiefReplicaBackend.cloudKeyPrefix) {
                    message.clientMessageID = String(id.dropFirst(ChiefReplicaBackend.cloudKeyPrefix.count))
                }
                return message
            }
            return Copy(info: info, messages: messages)
        }
    }

    /// How the Cloud service answered one sent message.
    enum Outcome: Equatable {
        /// The Mac is offline: kept, delivered when it is back (1-based place in line).
        case queued(position: Int)
        /// The Mac was online and took it.
        case delivered
        case refused(String)

        /// The outcome a frame decides for `key`, or nil when the frame is about something else.
        static func of(_ frame: [String: Any], key: String) -> Outcome? {
            guard frame["idempotency_key"] as? String == key else { return nil }
            switch frame["t"] as? String {
            case "op.queued": return .queued(position: (frame["position"] as? NSNumber)?.intValue ?? 1)
            case "reject": return .refused(frame["message"] as? String ?? frame["code"] as? String ?? "refused")
            case "request-settled": return (frame["ok"] as? Bool) == true ? .delivered : nil
            default: return nil
            }
        }
    }

    actor Core {
        let http: ChiefCloudHTTP
        nonisolated let host: String
        let wire: ChiefWire
        private var stream: String { "host:\(host)/chief" }
        private var continuation: AsyncStream<ConversationBackendEvent>.Continuation?
        private var socket: URLSessionWebSocketTask?
        private var runner: Task<Void, Never>?
        private var closed = false
        private var copy: Copy?
        private var eventSeq = 0
        private var everConnected = false
        /// Sends waiting for their answer, by key.
        private var waiting: [String: CheckedContinuation<Outcome, Never>] = [:]
        /// Answers that came before their send started waiting, by key.
        private var early: [String: Outcome] = [:]

        init(http: ChiefCloudHTTP, host: String, identity: ChiefIdentity) {
            self.http = http
            self.host = host
            wire = ChiefWire(identity: identity)
        }

        func start(_ continuation: AsyncStream<ConversationBackendEvent>.Continuation) {
            self.continuation = continuation
            // task-owner: the backend's lifetime; ends on close()
            runner = Task { await self.loop() }
        }

        func close() {
            closed = true
            runner?.cancel()
            socket?.cancel(with: .goingAway, reason: nil)
            for (_, waiter) in waiting { waiter.resume(returning: .refused("closed")) }
            waiting = [:]
            continuation?.finish()
        }

        func history(beforeSeq: Int?, limit: Int) -> ConversationHistoryPage {
            let all = copy?.messages ?? []
            let below = beforeSeq.map { seq in all.filter { ($0.seq ?? 0) < seq } } ?? all
            return ConversationHistoryPage(messages: Array(below.suffix(limit)), hasMore: false)
        }

        func recent(_ count: Int) -> [ConversationMessage] {
            Array((copy?.messages ?? []).suffix(count))
        }

        func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage {
            guard draft.attachmentIDs.isEmpty, draft.poll == nil else {
                throw ConversationBackendError(code: -32601, message: String(localized: "Your Mac is offline. Only text can wait for it."))
            }
            guard let socket else {
                throw ConversationBackendError(code: -1, message: String(localized: "mobile.chief.offline", defaultValue: "Chief is offline.", bundle: .module))
            }
            let key = draft.clientMessageID
            let frame: [String: Any] = ["t": "op", "stream": stream, "op": "conversation.message.send",
                                        "params": ["text": draft.text], "idempotency_key": key, "origin": "user"]
            // The answer may come while the send is in flight (the actor is reentrant): it waits in `early`.
            do {
                try await socket.send(.string(try ChiefCloudBackend.Core.text(frame)))
            } catch {
                throw ConversationBackendError(code: -1, message: error.localizedDescription)
            }
            let outcome: Outcome
            if let known = early.removeValue(forKey: key) {
                outcome = known
            } else {
                outcome = await withCheckedContinuation { (waiter: CheckedContinuation<Outcome, Never>) in
                    waiting[key] = waiter
                }
            }
            switch outcome {
            case .refused(let why):
                throw ConversationBackendError(code: -32000, message: why)
            case .queued, .delivered:
                // The row keeps its local id (the store's `local:<client id>`), so the
                // Mac's copy, which names the real message by the same client id, replaces it.
                return ConversationMessage(id: "local:\(key)", seq: nil, clientMessageID: key, senderID: wire.identity.meID,
                                           sentAt: Date(), text: draft.text, delivery: .sent)
            }
        }

        private func answer(_ key: String, _ outcome: Outcome) {
            if let waiter = waiting.removeValue(forKey: key) {
                waiter.resume(returning: outcome)
            } else if early.count < 64 {
                early[key] = outcome
            }
        }

        private func loop() async {
            var attempt = 0
            while !closed, !Task.isCancelled {
                let welcomed = await connectOnce()
                if closed || Task.isCancelled { return }
                continuation?.yield(.disconnected(reason: String(localized: "mobile.chief.reconnecting", defaultValue: "Reconnecting…", bundle: .module)))
                attempt = welcomed ? 0 : attempt + 1
                // A bounded, cancellable wait between dials (close() cancels the runner).
                try? await Task.sleep(for: ChiefCloudBackend.Core.retryDelay(attempt: attempt))
            }
        }

        private func socketURL() -> URL? {
            guard var components = URLComponents(url: http.base, resolvingAgainstBaseURL: false) else { return nil }
            components.scheme = components.scheme == "http" ? "ws" : "wss"
            components.path = "/v1/wire/host/\(host)"
            components.query = nil
            return components.url
        }

        private func connectOnce() async -> Bool {
            guard let url = socketURL(), let token = try? await http.token(forceRefresh: false) else { return false }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
            request.setValue("cmux.wire.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
            let task = http.session.webSocketTask(with: request)
            socket = task
            task.resume()
            defer {
                task.cancel(with: .goingAway, reason: nil)
                if socket === task { socket = nil }
                for (_, waiter) in waiting { waiter.resume(returning: .refused(String(localized: "The connection dropped; try again."))) }
                waiting = [:]
            }
            var welcomed = false
            do {
                while !closed, !Task.isCancelled {
                    guard let text = try await ChiefCloudBackend.Core.receive(task),
                          let data = text.data(using: .utf8),
                          let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if frame["t"] as? String == "welcome" {
                        welcomed = true
                        try await task.send(.string(try ChiefCloudBackend.Core.text(["t": "subscribe", "stream": stream])))
                        continue
                    }
                    handle(frame)
                }
            } catch {}
            return welcomed
        }

        private func handle(_ frame: [String: Any]) {
            if let key = frame["idempotency_key"] as? String, let outcome = Outcome.of(frame, key: key) {
                answer(key, outcome)
            }
            guard frame["t"] as? String == "snapshot", frame["stream"] as? String == stream,
                  let state = frame["state"] as? [String: Any], let next = Copy.decode(state, wire: wire) else { return }
            copy = next
            continuation?.yield(.connected(info: next.info, meID: wire.identity.meID, lagged: everConnected))
            everConnected = true
            for message in next.messages {
                eventSeq += 1
                continuation?.yield(.message(message, eventSeq: eventSeq))
            }
        }
    }
}
