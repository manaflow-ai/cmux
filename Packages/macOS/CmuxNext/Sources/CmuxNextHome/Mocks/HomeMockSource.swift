public import Foundation

/// A paged transcript source for demos, tests and the bench: confirmed
/// history from a ``HomeMockHistory`` (memory or the read-only SQLite file),
/// messages confirmed in this session kept in memory after it, an intent log
/// of pending sends, typing and a read cursor. Mutations emit the same
/// changes the App's mirror would.
@MainActor
public final class HomeMockSource: HomeTranscriptSource {
    public let conversationID: String
    public let participants: [HomeParticipant]
    private let history: any HomeMockHistory
    /// Confirmed after launch (seq > history.count).
    private var session: [HomeMessage] = []
    /// Edits of history messages made in this session, by seq.
    private var overrides: [Int: HomeMessage] = [:]
    public private(set) var pendingMessages: [HomeMessage] = []
    public private(set) var typingParticipantIDs: [String] = []
    public private(set) var readThroughSeq: Int?
    private var handlers: [Int: @MainActor (HomeTranscriptChange) -> Void] = [:]
    private var nextHandler = 0
    private var nextClientID = 0

    public init(conversationID: String, participants: [HomeParticipant], history: any HomeMockHistory,
                readThroughSeq: Int? = nil) {
        self.conversationID = conversationID
        self.participants = participants
        self.history = history
        self.readThroughSeq = readThroughSeq ?? (history.count > 0 ? history.count : nil)
    }

    public var meID: String { participants.first(where: \.isMe)?.id ?? "" }
    public var newestSeq: Int? { let n = history.count + session.count; return n > 0 ? n : nil }
    public var oldestSeq: Int? { newestSeq == nil ? nil : 1 }

    public func page(before seq: Int, limit: Int) async throws -> [HomeMessage] {
        let upper = min(seq, history.count + session.count + 1)
        let lower = max(1, upper - limit)
        guard lower < upper else { return [] }
        var out: [HomeMessage] = []
        if lower <= history.count {
            out = await history.messages(in: lower..<min(upper, history.count + 1))
            for (index, message) in out.enumerated() { if let seq = message.seq, let edited = overrides[seq] { out[index] = edited } }
        }
        let sessionLower = max(lower, history.count + 1)
        if sessionLower < upper {
            out += session[(sessionLower - history.count - 1)..<(upper - history.count - 1)]
        }
        return out
    }

    public func observe(_ handler: @escaping @MainActor (HomeTranscriptChange) -> Void) -> HomeObservation {
        nextHandler += 1
        let id = nextHandler
        handlers[id] = handler
        return HomeObservation { [weak self] in self?.handlers[id] = nil }
    }

    private func emit(_ change: HomeTranscriptChange) {
        for handler in handlers.values { handler(change) }
    }

    // MARK: Mutations (what the owner and the intent log would report)

    /// A send enters the intent log; returns its client message id.
    @discardableResult
    public func addPending(_ parts: [HomePart], replyTo: String? = nil, at date: Date = Date()) -> String {
        nextClientID += 1
        let clientMsgID = "cm_\(conversationID)_\(nextClientID)"
        let message = HomeMessage.pending(clientMsgID: clientMsgID, authorID: meID, parts: parts, replyTo: replyTo,
                                          createdAt: date)
        pendingMessages.append(message)
        emit(.pendingAdded(message))
        return clientMsgID
    }

    /// The owner confirmed a pending send: it gets the next seq and settles in place.
    @discardableResult
    public func confirm(clientMsgID: String) -> HomeMessage? {
        guard let index = pendingMessages.firstIndex(where: { $0.clientMsgID == clientMsgID }) else { return nil }
        var message = pendingMessages.remove(at: index)
        let seq = (newestSeq ?? 0) + 1
        message.seq = seq
        message.id = "msg_\(conversationID)_\(seq)"
        message.delivery = .sent
        session.append(message)
        emit(.pendingResolved(clientMsgID: clientMsgID, confirmed: message))
        return message
    }

    public func fail(clientMsgID: String, reason: String) {
        guard let index = pendingMessages.firstIndex(where: { $0.clientMsgID == clientMsgID }) else { return }
        pendingMessages[index].delivery = .failed(reason)
        emit(.pendingFailed(clientMsgID: clientMsgID, reason: reason))
    }

    /// A failed send goes back to sending under the same client message id.
    public func retry(clientMsgID: String) {
        guard let index = pendingMessages.firstIndex(where: { $0.clientMsgID == clientMsgID }) else { return }
        pendingMessages[index].delivery = .sending
        emit(.pendingAdded(pendingMessages[index]))
    }

    /// Another participant's message arrives confirmed.
    @discardableResult
    public func receive(_ parts: [HomePart], from authorID: String, replyTo: String? = nil,
                        at date: Date = Date()) -> HomeMessage {
        let seq = (newestSeq ?? 0) + 1
        let message = HomeMessage(id: "msg_\(conversationID)_\(seq)", seq: seq, clientMsgID: "in_\(seq)",
                                  authorID: authorID, parts: parts, replyTo: replyTo, createdAt: date)
        session.append(message)
        emit(.appended([message]))
        return message
    }

    public func setTyping(_ ids: [String]) {
        guard ids != typingParticipantIDs else { return }
        typingParticipantIDs = ids
        emit(.typing(ids))
    }

    public func setReadThrough(_ seq: Int) {
        guard seq > (readThroughSeq ?? 0) else { return }
        readThroughSeq = seq
        emit(.readThrough(seq))
    }

    /// Replaces a confirmed message (reaction, edit, retraction).
    public func update(_ message: HomeMessage) {
        guard let seq = message.seq else { return }
        if seq > history.count, seq - history.count - 1 < session.count {
            session[seq - history.count - 1] = message
        } else {
            overrides[seq] = message
        }
        emit(.updated(message))
    }
}
