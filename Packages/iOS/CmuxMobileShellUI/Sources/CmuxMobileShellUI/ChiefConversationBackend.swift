import CmuxConversationCore
import CmuxMobileShell
import Foundation

/// ConversationBackend adapter for the Mac-owned Chief transcript.
///
/// Chief currently exposes request/response RPCs rather than a change event.
/// The adapter polls while the conversation is visible and refreshes its
/// newest page after each send, so the generic Messages UI remains live on
/// hosts that predate a Chief event topic.
final class ChiefConversationBackend: ConversationBackend, @unchecked Sendable {
    private let client: MobileChiefClient
    private let conversationID: String
    private let fallbackTitle: String
    // Concurrency carve-out: ConversationBackend exposes synchronous lifecycle
    // methods while its polling task is asynchronous, so state needs one small
    // critical section instead of an actor hop from every callback.
    private let stateLock = NSLock()
    private var state = State()

    private struct State {
        var previousMessagesByID: [String: MobileChiefMessage] = [:]
        var pendingSends: [String: PendingSend] = [:]
        var meID = "mobile-user"
        var pollTask: Task<Void, Never>?
        var continuation: AsyncStream<ConversationBackendEvent>.Continuation?
        var closed = false
    }

    private struct PendingSend {
        let clientMessageID: String
        let text: String
        let startedAt: Date
        var serverMessageID: String?
    }

    init(client: MobileChiefClient, conversationID: String, title: String) {
        self.client = client
        self.conversationID = conversationID
        self.fallbackTitle = title
    }

    func events() -> AsyncStream<ConversationBackendEvent> {
        let (stream, continuation) = AsyncStream<ConversationBackendEvent>.makeStream()
        let task = Task { [weak self] in
            await self?.poll(continuation: continuation)
        }
        let previous = withState { state -> (
            Task<Void, Never>?,
            AsyncStream<ConversationBackendEvent>.Continuation?
        ) in
            guard !state.closed else {
                continuation.finish()
                return (task, nil)
            }
            let previous = (state.pollTask, state.continuation)
            state.continuation = continuation
            state.pollTask = task
            return previous
        }
        previous.0?.cancel()
        previous.1?.finish()
        return stream
    }

    func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
        let result = try await client.read(conversation: conversationID, limit: limit)
        let mapped = result.messages.map {
            map($0, clientMessageID: clientMessageID(for: $0))
        }
        withState { state in
            state.previousMessagesByID.merge(
                result.messages.reduce(into: [:]) { $0[$1.id] = $1 },
                uniquingKeysWith: { _, new in new }
            )
        }
        return ConversationHistoryPage(messages: mapped, hasMore: false)
    }

    func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage {
        let startedAt = Date()
        withState { state in
            state.pendingSends[draft.clientMessageID] = PendingSend(
                clientMessageID: draft.clientMessageID,
                text: draft.text,
                startedAt: startedAt,
                serverMessageID: nil
            )
        }
        let sendResult: MobileChiefSendResult
        do {
            sendResult = try await client.send(
                draft.text,
                conversation: conversationID,
                clientMessageID: draft.clientMessageID
            )
        } catch {
            withState { $0.pendingSends.removeValue(forKey: draft.clientMessageID) }
            throw error
        }
        withState { state in
            state.pendingSends[draft.clientMessageID]?.serverMessageID = sendResult.messageID
        }
        do {
            let result = try await client.read(conversation: conversationID, limit: 200)
            let exactClientMessageIDs = Set(
                [draft.clientMessageID, sendResult.clientMessageID].compactMap { $0 }
            )
            let sent = result.messages.first { message in
                guard let clientMessageID = message.clientMessageID else { return false }
                return exactClientMessageIDs.contains(clientMessageID)
            } ?? sendResult.messageID.flatMap { messageID in
                result.messages.first { $0.id == messageID }
            } ?? result.messages
                .filter {
                    $0.authorKind == "human"
                        && $0.text == draft.text
                        && $0.at >= startedAt.addingTimeInterval(-5)
                }
                .max(by: { $0.at < $1.at })
            if let sent {
                withState { $0.pendingSends.removeValue(forKey: draft.clientMessageID) }
                var message = map(sent, clientMessageID: draft.clientMessageID)
                message.clientMessageID = draft.clientMessageID
                message.delivery = .sent
                return message
            }
        } catch {
            // Chief accepted the send, but its follow-up read may transiently
            // fail. Keep the pending correlation so the poll can merge the
            // committed echo into the optimistic row instead of duplicating it.
        }
        // Some Chief owners acknowledge before the committed message is
        // visible to `chief.read`; preserve the optimistic row identity so a
        // later poll can replace it without duplicating the bubble.
        return ConversationMessage(
            id: "local:\(draft.clientMessageID)",
            seq: nil,
            clientMessageID: draft.clientMessageID,
            senderID: withState { $0.meID },
            sentAt: Date(),
            text: draft.text,
            delivery: .sent
        )
    }

    func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage {
        throw unsupported("reactions")
    }

    func edit(messageID: String, text: String) async throws -> ConversationMessage {
        throw unsupported("editing")
    }

    func unsend(messageID: String) async throws -> ConversationMessage {
        throw unsupported("unsend")
    }

    func setTyping(_ isTyping: Bool) async {}

    func markRead(upToSeq: Int) async {}

    func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment {
        throw unsupported("attachments")
    }

    func close() {
        let resources: (
            Task<Void, Never>?,
            AsyncStream<ConversationBackendEvent>.Continuation?
        ) = withState { state in
            state.closed = true
            let resources = (state.pollTask, state.continuation)
            state.pollTask = nil
            state.continuation = nil
            return resources
        }
        resources.0?.cancel()
        resources.1?.finish()
    }

    private func poll(continuation: AsyncStream<ConversationBackendEvent>.Continuation) async {
        var first = true
        var connected = false
        var reportedFailure = false
        var lastSeq: UInt64 = 0
        var eventSeq = 0
        while !Task.isCancelled && !isClosed {
            do {
                let result = try await client.read(conversation: conversationID, limit: 200)
                guard !Task.isCancelled, !isClosed else { return }
                let mappedInfo = info(from: result.messages)
                if first {
                    first = false
                    withState { state in
                        state.previousMessagesByID = Dictionary(
                            uniqueKeysWithValues: result.messages.map { ($0.id, $0) }
                        )
                    }
                    lastSeq = result.messages.map(\.seq).max() ?? 0
                    continuation.yield(.connected(
                        info: mappedInfo.info,
                        meID: mappedInfo.meID,
                        lagged: false
                    ))
                    continuation.yield(.readState(ConversationReadState(
                        lastReadSeq: safeInt(lastSeq),
                        unreadCount: 0,
                        headSeq: safeInt(lastSeq)
                    )))
                    connected = true
                } else {
                    if !connected {
                        continuation.yield(.connected(
                            info: mappedInfo.info,
                            meID: mappedInfo.meID,
                            lagged: true
                        ))
                        connected = true
                    }
                    for message in result.messages {
                        let previous = withState { $0.previousMessagesByID[message.id] }
                        guard previous != message else { continue }
                        if eventSeq < Int.max {
                            eventSeq = max(eventSeq + 1, safeInt(message.seq))
                        }
                        continuation.yield(.message(
                            map(message, clientMessageID: clientMessageID(for: message)),
                            eventSeq: eventSeq
                        ))
                    }
                    withState { state in
                        state.previousMessagesByID = Dictionary(
                            uniqueKeysWithValues: result.messages.map { ($0.id, $0) }
                        )
                    }
                    lastSeq = max(lastSeq, result.messages.map(\.seq).max() ?? 0)
                    continuation.yield(.readState(ConversationReadState(
                        lastReadSeq: safeInt(lastSeq),
                        unreadCount: 0,
                        headSeq: safeInt(lastSeq)
                    )))
                }
                reportedFailure = false
            } catch {
                connected = false
                if !reportedFailure {
                    continuation.yield(.disconnected(reason: String(describing: error)))
                    reportedFailure = true
                }
            }
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                return
            }
        }
    }

    private func info(from messages: [MobileChiefMessage]) -> (info: ConversationInfo, meID: String) {
        let human = messages.first(where: { $0.authorKind == "human" })?.authorID
            ?? withState { $0.meID }
        withState { $0.meID = human }
        var participants: [ConversationParticipant] = []
        var seen = Set<String>()
        for message in messages {
            guard seen.insert(message.authorID).inserted else { continue }
            participants.append(ConversationParticipant(
                id: message.authorID,
                name: message.author.isEmpty ? message.authorID : message.author,
                initials: initials(for: message.author),
                colorHex: message.authorKind == "human" ? "#0284FE" : "#8E8E93",
                isMe: message.authorID == human
            ))
        }
        if !seen.contains(human) {
            participants.append(ConversationParticipant(
                id: human,
                name: "You",
                initials: "YO",
                colorHex: "#0284FE",
                isMe: true
            ))
        }
        return (ConversationInfo(
            id: conversationID,
            title: fallbackTitle.isEmpty ? conversationID : fallbackTitle,
            kind: .direct,
            participants: participants
        ), human)
    }

    private func map(
        _ message: MobileChiefMessage,
        clientMessageID: String? = nil
    ) -> ConversationMessage {
        let senderIsMe = withState { state in
            let isMe = message.authorID == state.meID || message.authorKind == "human"
            if isMe { state.meID = message.authorID }
            return isMe
        }
        let text = message.text.isEmpty && !message.parts.isEmpty
            ? message.parts.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }.joined(separator: " · ")
            : message.text
        return ConversationMessage(
            id: message.id,
            seq: safeInt(message.seq),
            clientMessageID: clientMessageID,
            senderID: message.authorID,
            sentAt: message.at,
            text: text,
            replyToID: message.threadRoot,
            delivery: senderIsMe ? .sent : nil
        )
    }

    private func map(_ messages: [MobileChiefMessage]) -> [ConversationMessage] {
        messages.map { map($0) }
    }

    /// Chief's transcript does not echo the mobile client id. Correlate a
    /// human message with the optimistic row while its send is pending.
    private func clientMessageID(for message: MobileChiefMessage) -> String? {
        guard message.authorKind == "human" else { return nil }
        return withState { state in
            let cutoff = Date().addingTimeInterval(-300)
            state.pendingSends = state.pendingSends.filter { $0.value.startedAt >= cutoff }
            if let clientMessageID = message.clientMessageID,
               state.pendingSends[clientMessageID] != nil {
                state.pendingSends.removeValue(forKey: clientMessageID)
                return clientMessageID
            }
            guard let pending = state.pendingSends.values.filter({ pending in
                (pending.serverMessageID == message.id
                    || (pending.serverMessageID == nil && pending.text == message.text))
                    && message.at >= pending.startedAt.addingTimeInterval(-5)
            })
                .min(by: { $0.startedAt < $1.startedAt }) else { return nil }
            state.pendingSends.removeValue(forKey: pending.clientMessageID)
            return pending.clientMessageID
        }
    }

    private var isClosed: Bool {
        withState { $0.closed }
    }

    private func withState<T>(_ body: (inout State) -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body(&state)
    }

    private func initials(for name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" })
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    private func safeInt(_ value: UInt64) -> Int {
        value > UInt64(Int.max) ? Int.max : Int(value)
    }

    private func unsupported(_ operation: String) -> ConversationBackendError {
        ConversationBackendError(code: -32601, message: "Chief does not support \(operation)")
    }
}
