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
    private var pollTask: Task<Void, Never>?
    private var continuation: AsyncStream<ConversationBackendEvent>.Continuation?
    private var latestMessages: [MobileChiefMessage] = []
    private var meID = "mobile-user"
    private var closed = false

    init(client: MobileChiefClient, conversationID: String, title: String) {
        self.client = client
        self.conversationID = conversationID
        self.fallbackTitle = title
    }

    func events() -> AsyncStream<ConversationBackendEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            self.pollTask?.cancel()
            self.pollTask = Task { [weak self] in
                await self?.poll(continuation: continuation)
            }
        }
    }

    func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
        let result = try await client.read(conversation: conversationID, limit: limit)
        latestMessages = result.messages
        let mapped = map(result.messages)
        return ConversationHistoryPage(messages: mapped, hasMore: false)
    }

    func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage {
        _ = try await client.send(draft.text, conversation: conversationID)
        let result = try await client.read(conversation: conversationID, limit: 200)
        latestMessages = result.messages
        if let sent = result.messages.last(where: { $0.text == draft.text && $0.authorKind == "human" }) {
            var message = map(sent)
            message.clientMessageID = draft.clientMessageID
            message.delivery = .sent
            return message
        }
        // Some Chief owners acknowledge before the committed message is
        // visible to `chief.read`; preserve the optimistic row identity so a
        // later poll can replace it without duplicating the bubble.
        return ConversationMessage(
            id: "chief-local-\(draft.clientMessageID)",
            seq: nil,
            clientMessageID: draft.clientMessageID,
            senderID: meID,
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
        closed = true
        pollTask?.cancel()
        pollTask = nil
        continuation?.finish()
        continuation = nil
    }

    private func poll(continuation: AsyncStream<ConversationBackendEvent>.Continuation) async {
        var first = true
        var lastSeq: UInt64 = 0
        while !Task.isCancelled && !closed {
            do {
                let result = try await client.read(conversation: conversationID, limit: 200)
                latestMessages = result.messages
                let mappedInfo = info(from: result.messages)
                if first {
                    first = false
                    lastSeq = result.messages.map(\.seq).max() ?? 0
                    continuation.yield(.connected(
                        info: mappedInfo.info,
                        meID: mappedInfo.meID,
                        lagged: false
                    ))
                    continuation.yield(.readState(ConversationReadState(
                        lastReadSeq: lastSeq > UInt64(Int.max) ? Int.max : Int(lastSeq),
                        unreadCount: 0,
                        headSeq: lastSeq > UInt64(Int.max) ? Int.max : Int(lastSeq)
                    )))
                } else {
                    for message in result.messages where message.seq > lastSeq {
                        continuation.yield(.message(map(message), eventSeq: safeInt(message.seq)))
                    }
                    lastSeq = max(lastSeq, result.messages.map(\.seq).max() ?? 0)
                    continuation.yield(.readState(ConversationReadState(
                        lastReadSeq: safeInt(lastSeq),
                        unreadCount: 0,
                        headSeq: safeInt(lastSeq)
                    )))
                }
            } catch {
                if !first { continuation.yield(.disconnected(reason: String(describing: error))) }
            }
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch { return }
        }
    }

    private func info(from messages: [MobileChiefMessage]) -> (info: ConversationInfo, meID: String) {
        let human = messages.first(where: { $0.authorKind == "human" })?.authorID ?? meID
        meID = human
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

    private func map(_ message: MobileChiefMessage) -> ConversationMessage {
        let senderIsMe = message.authorID == meID || message.authorKind == "human"
        if senderIsMe { meID = message.authorID }
        let text = message.text.isEmpty && !message.parts.isEmpty
            ? message.parts.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }.joined(separator: " · ")
            : message.text
        return ConversationMessage(
            id: message.id,
            seq: safeInt(message.seq),
            clientMessageID: nil,
            senderID: message.authorID,
            sentAt: message.at,
            text: text,
            replyToID: message.threadRoot,
            delivery: senderIsMe ? .sent : nil
        )
    }

    private func map(_ messages: [MobileChiefMessage]) -> [ConversationMessage] {
        messages.map(map)
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
