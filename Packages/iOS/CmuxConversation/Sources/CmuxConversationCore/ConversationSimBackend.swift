import Foundation

/// `ConversationBackend` for `services/conversation-sim` (see its PROTOCOL.md):
/// JSON-RPC 2.0 over a WebSocket, media over HTTP. Reconnects with capped
/// backoff and resumes from the last delivered event.
public final class ConversationSimBackend: ConversationBackend, @unchecked Sendable {
    private let core: Core

    /// `endpoint` is the WebSocket URL, e.g. `ws://127.0.0.1:4870/ws?conversation=group`.
    public init(endpoint: URL, clientID: String = UUID().uuidString) {
        core = Core(endpoint: endpoint, clientID: clientID)
    }

    public func events() -> AsyncStream<ConversationBackendEvent> {
        let (stream, continuation) = AsyncStream<ConversationBackendEvent>.makeStream(bufferingPolicy: .unbounded)
        Task { await core.start(continuation) }
        return stream
    }

    public func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
        var params: [String: Any] = ["limit": limit]
        params["beforeSeq"] = beforeSeq ?? NSNull()
        let result = try await core.request("history", params: JSONBox(params), timeout: .seconds(20)).value
        let base = await core.httpBase
        let messages = (result["messages"] as? [[String: Any]] ?? []).compactMap { WireDecoding.message($0, base: base) }
        return ConversationHistoryPage(messages: messages, hasMore: result["hasMore"] as? Bool ?? false)
    }

    public func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage {
        var params: [String: Any] = ["clientMessageId": draft.clientMessageID, "text": draft.text]
        if let replyTo = draft.replyToID { params["replyToId"] = replyTo }
        if !draft.attachmentIDs.isEmpty { params["attachmentIds"] = draft.attachmentIDs }
        let result = try await core.request("send", params: JSONBox(params), timeout: .seconds(15)).value
        return try await core.decodeMessage(JSONBox(result["message"] as? [String: Any] ?? [:]))
    }

    public func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage {
        let params: [String: Any] = ["messageId": messageID, "reaction": reaction?.rawValue ?? NSNull()]
        let result = try await core.request("react", params: JSONBox(params), timeout: .seconds(15)).value
        return try await core.decodeMessage(JSONBox(result["message"] as? [String: Any] ?? [:]))
    }

    public func edit(messageID: String, text: String) async throws -> ConversationMessage {
        let params: [String: Any] = ["messageId": messageID, "text": text]
        let result = try await core.request("edit", params: JSONBox(params), timeout: .seconds(15)).value
        return try await core.decodeMessage(JSONBox(result["message"] as? [String: Any] ?? [:]))
    }

    public func setTyping(_ isTyping: Bool) async {
        _ = try? await core.request("typing", params: JSONBox(["isTyping": isTyping]), timeout: .seconds(5))
    }

    public func markRead(upToSeq: Int) async {
        _ = try? await core.request("markRead", params: JSONBox(["upToSeq": upToSeq]), timeout: .seconds(5))
    }

    public func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment {
        let base = await core.httpBase
        var request = URLRequest(url: base.appendingPathComponent("upload"))
        request.httpMethod = "POST"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        let (body, response) = try await URLSession.shared.upload(for: request, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let attachment = WireDecoding.attachment(json["attachment"] as? [String: Any] ?? [:], base: base) else {
            throw ConversationBackendError(code: -1, message: "upload failed")
        }
        return attachment
    }

    public func close() {
        Task { await core.close() }
    }

    // MARK: -

    actor Core {
        let endpoint: URL
        let clientID: String
        let session = URLSession(configuration: .ephemeral)
        var task: URLSessionWebSocketTask?
        var continuation: AsyncStream<ConversationBackendEvent>.Continuation?
        var nextID = 1
        var pending: [Int: CheckedContinuation<JSONBox, any Error>] = [:]
        var lastEventSeq: Int?
        var closed = false
        var runTask: Task<Void, Never>?
        var connectedWaiters: [CheckedContinuation<Void, Never>] = []
        var isReady = false

        init(endpoint: URL, clientID: String) {
            self.endpoint = endpoint
            self.clientID = clientID
        }

        var httpBase: URL {
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            components.scheme = endpoint.scheme == "wss" ? "https" : "http"
            components.path = ""
            components.query = nil
            return components.url!
        }

        func start(_ continuation: AsyncStream<ConversationBackendEvent>.Continuation) {
            self.continuation = continuation
            runTask = Task { await self.runLoop() }
        }

        func close() {
            closed = true
            runTask?.cancel()
            task?.cancel(with: .goingAway, reason: nil)
            failAll(ConversationBackendError(code: -2, message: "closed"))
            continuation?.finish()
        }

        private func runLoop() async {
            var attempt = 0
            while !closed, !Task.isCancelled {
                let socket = session.webSocketTask(with: endpoint)
                socket.maximumMessageSize = 64 * 1024 * 1024
                task = socket
                socket.resume()
                let receiver = Task { await self.receiveLoop(socket) }
                do {
                    try await hello()
                    attempt = 0
                    await receiver.value
                } catch {
                    #if DEBUG
                    NSLog("conversation-sim dial failed: %@", String(describing: error))
                    #endif
                    receiver.cancel()
                    socket.cancel(with: .abnormalClosure, reason: nil)
                }
                isReady = false
                failAll(ConversationBackendError(code: -3, message: "disconnected"))
                guard !closed else { return }
                continuation?.yield(.disconnected(reason: "socket closed"))
                attempt += 1
                let delay = min(8000, 250 * (1 << min(attempt, 5)))
                try? await Task.sleep(for: .milliseconds(delay))
            }
        }

        private func hello() async throws {
            var params: [String: Any] = ["clientId": clientID]
            if let lastEventSeq { params["resumeAfterEventSeq"] = lastEventSeq }
            let result = try await send("hello", params: params, timeout: .seconds(10)).value
            guard let conversation = result["conversation"] as? [String: Any],
                  let info = WireDecoding.conversation(conversation),
                  let me = (result["me"] as? String) ?? ((result["me"] as? [String: Any])?["id"] as? String) else {
                throw ConversationBackendError(code: -4, message: "bad hello")
            }
            let lagged = result["lagged"] as? Bool ?? false
            if lagged || lastEventSeq == nil {
                lastEventSeq = result["headEventSeq"] as? Int ?? 0
            }
            isReady = true
            let waiters = connectedWaiters
            connectedWaiters = []
            waiters.forEach { $0.resume() }
            continuation?.yield(.connected(info: info, meID: me, lagged: lagged))
        }

        private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
            while !Task.isCancelled {
                guard let message = try? await socket.receive() else { return }
                let data: Data
                switch message {
                case let .string(text): data = Data(text.utf8)
                case let .data(bytes): data = bytes
                @unknown default: continue
                }
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                handle(object)
            }
        }

        private func handle(_ object: [String: Any]) {
            if let id = object["id"] as? Int, let waiter = pending.removeValue(forKey: id) {
                if let error = object["error"] as? [String: Any] {
                    waiter.resume(throwing: ConversationBackendError(
                        code: error["code"] as? Int ?? -1,
                        message: error["message"] as? String ?? "error"
                    ))
                } else {
                    waiter.resume(returning: JSONBox(object["result"] as? [String: Any] ?? [:]))
                }
                return
            }
            guard let method = object["method"] as? String else { return }
            let params = object["params"] as? [String: Any] ?? [:]
            switch method {
            case "event":
                guard let eventSeq = params["eventSeq"] as? Int,
                      let raw = params["message"] as? [String: Any],
                      let message = WireDecoding.message(raw, base: httpBase) else { return }
                if let last = lastEventSeq, eventSeq <= last { return }
                lastEventSeq = eventSeq
                continuation?.yield(.message(message, eventSeq: eventSeq))
            case "typing":
                guard let participant = params["participantId"] as? String else { return }
                continuation?.yield(.typing(participantID: participant, isTyping: params["isTyping"] as? Bool ?? false))
            default:
                break
            }
        }

        /// A request that waits for the session to be ready (hello done).
        func request(_ method: String, params: JSONBox, timeout: Duration) async throws -> JSONBox {
            if !isReady {
                await withCheckedContinuation { connectedWaiters.append($0) }
            }
            return try await send(method, params: params.value, timeout: timeout)
        }

        private func send(_ method: String, params: [String: Any], timeout: Duration) async throws -> JSONBox {
            guard let socket = task else { throw ConversationBackendError(code: -3, message: "disconnected") }
            let id = nextID
            nextID += 1
            let frame: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
            let data = try JSONSerialization.data(withJSONObject: frame)
            let timeoutTask = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self.timeOut(id)
            }
            defer { timeoutTask.cancel() }
            return try await withCheckedThrowingContinuation { waiter in
                pending[id] = waiter
                socket.send(.string(String(decoding: data, as: UTF8.self))) { error in
                    guard let error else { return }
                    #if DEBUG
                    NSLog("conversation-sim send failed: %@", String(describing: error))
                    #endif
                    Task { await self.fail(id, error) }
                }
            }
        }

        private func timeOut(_ id: Int) {
            pending.removeValue(forKey: id)?.resume(throwing: ConversationBackendError(code: -5, message: "timed out"))
        }

        private func fail(_ id: Int, _ error: any Error) {
            pending.removeValue(forKey: id)?.resume(throwing: error)
        }

        private func failAll(_ error: any Error) {
            let waiters = pending
            pending = [:]
            waiters.values.forEach { $0.resume(throwing: error) }
        }

        func decodeMessage(_ raw: JSONBox) throws -> ConversationMessage {
            guard let message = WireDecoding.message(raw.value, base: httpBase) else {
                throw ConversationBackendError(code: -4, message: "bad message")
            }
            return message
        }
    }
}

/// JSON from `JSONSerialization` is immutable once parsed; this box lets it cross actors.
struct JSONBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

enum WireDecoding {
    static func conversation(_ raw: [String: Any]) -> ConversationInfo? {
        guard let id = raw["id"] as? String else { return nil }
        let participants = (raw["participants"] as? [[String: Any]] ?? []).compactMap { p -> ConversationParticipant? in
            guard let id = p["id"] as? String else { return nil }
            return ConversationParticipant(
                id: id,
                name: p["name"] as? String ?? id,
                initials: p["initials"] as? String ?? "",
                colorHex: p["colorHex"] as? String ?? "#8E8E93",
                isMe: p["isMe"] as? Bool ?? false
            )
        }
        return ConversationInfo(
            id: id,
            title: raw["title"] as? String ?? "",
            kind: ConversationKind(rawValue: raw["kind"] as? String ?? "") ?? .group,
            participants: participants
        )
    }

    static func message(_ raw: [String: Any], base: URL) -> ConversationMessage? {
        guard let id = raw["id"] as? String, let senderID = raw["senderId"] as? String else { return nil }
        let sentAt = date(raw["sentAt"]) ?? Date()
        let reactions = (raw["reactions"] as? [[String: Any]] ?? []).compactMap { r -> ConversationReactionMark? in
            guard let participant = r["participantId"] as? String,
                  let reaction = (r["reaction"] as? String).flatMap(ConversationReaction.init(rawValue:)) else { return nil }
            return ConversationReactionMark(participantID: participant, reaction: reaction)
        }
        let attachments = (raw["attachments"] as? [[String: Any]] ?? []).compactMap { attachment($0, base: base) }
        var delivery: ConversationDelivery?
        switch raw["status"] as? String {
        case "sent": delivery = .sent
        case "delivered": delivery = .delivered
        case "read": delivery = .read(date(raw["readAt"]))
        default: delivery = nil
        }
        return ConversationMessage(
            id: id,
            seq: raw["seq"] as? Int,
            clientMessageID: raw["clientMessageId"] as? String,
            senderID: senderID,
            sentAt: sentAt,
            text: raw["text"] as? String ?? "",
            replyToID: raw["replyToId"] as? String,
            replyCount: raw["replyCount"] as? Int ?? 0,
            editedAt: date(raw["editedAt"]),
            reactions: reactions,
            attachments: attachments,
            delivery: delivery
        )
    }

    static func attachment(_ raw: [String: Any], base: URL) -> ConversationAttachment? {
        guard let id = raw["id"] as? String else { return nil }
        var url: URL?
        if let string = raw["url"] as? String {
            url = string.hasPrefix("/") ? URL(string: string, relativeTo: base)?.absoluteURL : URL(string: string)
        }
        return ConversationAttachment(
            id: id,
            kind: .image,
            width: raw["width"] as? Int ?? 1024,
            height: raw["height"] as? Int ?? 768,
            url: url
        )
    }

    static func date(_ raw: Any?) -> Date? {
        guard let ms = raw as? Double ?? (raw as? Int).map(Double.init) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
