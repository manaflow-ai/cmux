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
        if !draft.mentions.isEmpty { params["mentions"] = draft.mentions.map(WireDecoding.wireMention) }
        if !draft.textRuns.isEmpty { params["textRuns"] = WireDecoding.wireRuns(draft.textRuns) }
        let result = try await core.request("send", params: JSONBox(params), timeout: .seconds(15)).value
        return try await core.decodeMessage(JSONBox(result["message"] as? [String: Any] ?? [:]))
    }

    public func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage {
        let params: [String: Any] = ["messageId": messageID, "reaction": reaction?.rawValue ?? NSNull()]
        let result = try await core.request("react", params: JSONBox(params), timeout: .seconds(15)).value
        return try await core.decodeMessage(JSONBox(result["message"] as? [String: Any] ?? [:]))
    }

    public func edit(messageID: String, text: String) async throws -> ConversationMessage {
        try await edit(messageID: messageID, text: text, textRuns: [])
    }

    public func edit(messageID: String, text: String, textRuns: [ConversationTextRun]) async throws -> ConversationMessage {
        var params: [String: Any] = ["messageId": messageID, "text": text]
        if !textRuns.isEmpty { params["textRuns"] = WireDecoding.wireRuns(textRuns) }
        let result = try await core.request("edit", params: JSONBox(params), timeout: .seconds(15)).value
        return try await core.decodeMessage(JSONBox(result["message"] as? [String: Any] ?? [:]))
    }

    public func unsend(messageID: String) async throws -> ConversationMessage {
        let result = try await core.request("unsend", params: JSONBox(["messageId": messageID]), timeout: .seconds(15)).value
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

    public func updateListState(_ change: ConversationListStateChange) async throws -> ConversationInfo {
        var params: [String: Any] = [:]
        if let pinned = change.pinned { params["pinned"] = pinned }
        if let pinOrder = change.pinOrder { params["pinOrder"] = pinOrder }
        if let muted = change.muted { params["muted"] = muted }
        if let markedUnread = change.markedUnread { params["markedUnread"] = markedUnread }
        if let deleted = change.deleted { params["deleted"] = deleted }
        let result = try await core.request("updateConversation", params: JSONBox(params), timeout: .seconds(15)).value
        guard let info = WireDecoding.conversation(result["conversation"] as? [String: Any] ?? [:]) else {
            throw ConversationBackendError(code: -4, message: "bad conversation")
        }
        return info
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
            if let read = WireDecoding.readState(result) { continuation?.yield(.readState(read)) }
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
            case "readState":
                guard let read = WireDecoding.readState(params) else { return }
                continuation?.yield(.readState(read))
            case "conversation":
                guard let info = WireDecoding.conversation(params["conversation"] as? [String: Any] ?? [:]) else { return }
                continuation?.yield(.conversationChanged(info))
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
    static func readState(_ raw: [String: Any]) -> ConversationReadState? {
        guard let lastRead = raw["lastReadSeq"] as? Int, let unread = raw["unreadCount"] as? Int else { return nil }
        return ConversationReadState(lastReadSeq: lastRead, unreadCount: unread, headSeq: raw["headSeq"] as? Int ?? lastRead)
    }

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
            participants: participants,
            listState: listState(raw)
        )
    }

    static func listState(_ raw: [String: Any]) -> ConversationListState {
        let pinned = raw["pinned"] as? Bool ?? false
        return ConversationListState(
            pinned: pinned,
            pinOrder: pinned ? raw["pinOrder"] as? Int : nil,
            muted: raw["muted"] as? Bool ?? false,
            markedUnread: raw["markedUnread"] as? Bool ?? false,
            deleted: raw["deleted"] as? Bool ?? false
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
            editCount: raw["editCount"] as? Int ?? 0,
            unsentAt: date(raw["unsentAt"]),
            reactions: reactions,
            attachments: attachments,
            delivery: delivery,
            mentions: (raw["mentions"] as? [[String: Any]] ?? []).compactMap(mention),
            textRuns: textRuns(raw["textRuns"], text: raw["text"] as? String ?? "")
        )
    }

    static func mention(_ raw: [String: Any]) -> ConversationMention? {
        guard let participant = raw["participantId"] as? String,
              let location = raw["location"] as? Int, let length = raw["length"] as? Int else { return nil }
        return ConversationMention(participantID: participant, location: location, length: length)
    }

    static func wireMention(_ mention: ConversationMention) -> [String: Any] {
        ["participantId": mention.participantID, "location": mention.location, "length": mention.length]
    }

    /// Wire runs (`{start, length, styles?, effect?}`, UTF-16) to the model.
    /// Unknown styles and effects are ignored rather than failing the message.
    static func textRuns(_ raw: Any?, text: String) -> [ConversationTextRun] {
        guard let list = raw as? [[String: Any]] else { return [] }
        let runs = list.compactMap { entry -> ConversationTextRun? in
            guard let start = entry["start"] as? Int, let length = entry["length"] as? Int else { return nil }
            return ConversationTextRun(
                location: start,
                length: length,
                style: ConversationTextStyle(wireNames: entry["styles"] as? [String] ?? []),
                effect: (entry["effect"] as? String).flatMap(ConversationTextEffect.init(rawValue:))
            )
        }
        return ConversationRichText.normalized(runs, utf16Count: text.utf16.count)
    }

    static func wireRuns(_ runs: [ConversationTextRun]) -> [[String: Any]] {
        runs.map { run in
            var entry: [String: Any] = ["start": run.location, "length": run.length]
            if !run.style.isEmpty { entry["styles"] = run.style.wireNames }
            if let effect = run.effect { entry["effect"] = effect.rawValue }
            return entry
        }
    }

    static func attachment(_ raw: [String: Any], base: URL) -> ConversationAttachment? {
        guard let id = raw["id"] as? String else { return nil }
        var url: URL?
        if let string = raw["url"] as? String {
            url = string.hasPrefix("/") ? URL(string: string, relativeTo: base)?.absoluteURL : URL(string: string)
        }
        let kind = ConversationAttachment.Kind(rawValue: raw["kind"] as? String ?? "") ?? .image
        var audio: ConversationAudioInfo?
        if kind == .audio {
            let durationMs = raw["durationMs"] as? Double ?? (raw["durationMs"] as? Int).map(Double.init) ?? 0
            let waveform = (raw["waveform"] as? [Any] ?? []).compactMap { value -> Float? in
                if let number = value as? NSNumber { return min(1, max(0, number.floatValue / 100)) }
                return nil
            }
            audio = ConversationAudioInfo(
                duration: durationMs / 1000,
                waveform: waveform,
                transcript: (raw["transcript"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                expiresAt: date(raw["expiresAt"]),
                isKept: raw["kept"] as? Bool ?? false
            )
        }
        return ConversationAttachment(
            id: id,
            kind: kind,
            width: raw["width"] as? Int ?? (kind == .audio ? 0 : 1024),
            height: raw["height"] as? Int ?? (kind == .audio ? 0 : 768),
            url: url,
            audio: audio
        )
    }

    static func date(_ raw: Any?) -> Date? {
        guard let ms = raw as? Double ?? (raw as? Int).map(Double.init) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}

extension ConversationSimBackend: ConversationAudioBackend {
    /// `POST /upload?kind=audio&durationMs=&waveform=` (levels 0...100, comma
    /// separated) with the recording bytes; the transcript rides in a header.
    public func uploadAudioRecording(_ data: Data, mimeType: String, info: ConversationAudioInfo) async throws -> ConversationAttachment {
        let base = await core.httpBase
        var components = URLComponents(url: base.appendingPathComponent("upload"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "kind", value: "audio"),
            URLQueryItem(name: "durationMs", value: String(Int((info.duration * 1000).rounded()))),
            URLQueryItem(name: "waveform", value: info.waveform.map { String(Int(($0 * 100).rounded())) }.joined(separator: ",")),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        if let transcript = info.transcript, !transcript.isEmpty {
            request.setValue(transcript.addingPercentEncoding(withAllowedCharacters: .alphanumerics), forHTTPHeaderField: "X-Transcript")
        }
        request.timeoutInterval = 60
        let (body, response) = try await URLSession.shared.upload(for: request, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let attachment = WireDecoding.attachment(json["attachment"] as? [String: Any] ?? [:], base: base) else {
            throw ConversationBackendError(code: -1, message: "upload failed")
        }
        return attachment
    }

    public func keepAudioMessage(messageID: String) async throws -> ConversationMessage {
        let result = try await core.request("keepAudio", params: JSONBox(["messageId": messageID]), timeout: .seconds(15)).value
        return try await core.decodeMessage(JSONBox(result["message"] as? [String: Any] ?? [:]))
    }

    public func markAudioPlayed(messageID: String) async {
        _ = try? await core.request("audioPlayed", params: JSONBox(["messageId": messageID]), timeout: .seconds(5))
    }
}
