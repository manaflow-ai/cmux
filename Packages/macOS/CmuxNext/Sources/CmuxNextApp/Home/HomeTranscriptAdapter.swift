import CmuxNextDaemon
import CmuxNextHome
import Foundation

/// Feeds one conversation's renderer from its session: the confirmed mirror,
/// the intent log and older pages read from the owner on demand.
@MainActor
final class HomeTranscriptAdapter: HomeTranscriptSource {
    let conversationID: String
    private let session: HomeConversationSession
    private unowned let service: HomeService
    /// Pending sends the renderer knows, by client id, with their last state.
    private var shownPending: [String: PendingConversationSend.State] = [:]

    init(session: HomeConversationSession, service: HomeService) {
        conversationID = session.id
        self.session = session
        self.service = service
        for entry in session.log.entries { shownPending[entry.clientMsgID] = entry.state }
    }

    var participants: [HomeParticipant] { service.participants(of: conversationID).map(HomeMapping.participant) }
    var newestSeq: Int? { session.mirror.flatMap { $0.summary.lastSeq > 0 ? Int($0.summary.lastSeq) : nil } }
    var oldestSeq: Int? { newestSeq == nil ? nil : 1 }
    var pendingMessages: [HomeMessage] { session.log.entries.map(HomeMapping.pending) }
    var typingParticipantIDs: [String] { session.typing.filter { $0 != service.actor }.sorted() }
    var readThroughSeq: Int? {
        guard let cursors = session.mirror?.summary.readCursors else { return nil }
        return cursors.filter { $0.key != service.actor }.values.max().map(Int.init)
    }

    func page(before seq: Int, limit: Int) async throws -> [HomeMessage] {
        guard seq > 1 else { return [] }
        // The newest pages come from the mirror's tail without a round trip.
        if let tail = session.mirror?.tail, let first = tail.first, UInt64(seq) > first.seq {
            let local = tail.filter { $0.seq < UInt64(seq) }.suffix(limit)
            if local.count == limit || local.first?.seq == 1 { return local.map(HomeMapping.message) }
        }
        guard let connection = service.connection else { throw DaemonError.notConnected }
        return try await ConversationClient(connection).history(conversationID, before: UInt64(seq), limit: limit).map(HomeMapping.message)
    }

    func observe(_ handler: @escaping @MainActor (HomeTranscriptChange) -> Void) -> HomeObservation {
        let token = session.observe { [weak self] change in self?.forward(change, to: handler) }
        return HomeObservation { [weak session] in session?.removeObserver(token) }
    }

    private func forward(_ change: HomeConversationSession.Change, to handler: @MainActor (HomeTranscriptChange) -> Void) {
        switch change {
        case .appended(let messages):
            var appended: [HomeMessage] = []
            for message in messages {
                if shownPending.removeValue(forKey: message.clientMsgID) != nil {
                    if !appended.isEmpty { handler(.appended(appended)); appended = [] }
                    handler(.pendingResolved(clientMsgID: message.clientMsgID, confirmed: HomeMapping.message(message)))
                } else {
                    appended.append(HomeMapping.message(message))
                }
            }
            if !appended.isEmpty { handler(.appended(appended)) }
        case .updated(let message):
            handler(.updated(HomeMapping.message(message)))
        case .pendingChanged:
            let current = Dictionary(session.log.entries.map { ($0.clientMsgID, $0) }, uniquingKeysWith: { $1 })
            for entry in session.log.entries where shownPending[entry.clientMsgID] != entry.state {
                switch entry.state {
                case .failed(let reason): handler(.pendingFailed(clientMsgID: entry.clientMsgID, reason: reason))
                case .sending where shownPending[entry.clientMsgID] == nil: handler(.pendingAdded(HomeMapping.pending(entry)))
                default: break
                }
                shownPending[entry.clientMsgID] = entry.state
            }
            // Settled by revision without an append we saw: the mirror holds it.
            for id in shownPending.keys where current[id] == nil {
                shownPending[id] = nil
                if let confirmed = session.mirror?.message(clientMsgID: id) {
                    handler(.pendingResolved(clientMsgID: id, confirmed: HomeMapping.message(confirmed)))
                }
            }
        case .typing:
            handler(.typing(typingParticipantIDs))
        case .reset:
            shownPending = Dictionary(session.log.entries.map { ($0.clientMsgID, $0.state) }, uniquingKeysWith: { $1 })
            handler(.reset)
        }
        if let seq = readThroughSeq { handler(.readThrough(seq)) }
    }
}
