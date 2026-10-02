import CmuxNextDaemon
import Foundation
import Observation
import os

/// One open local conversation: the confirmed mirror (written only by the
/// owner's changes) plus the intent log of unconfirmed sends
/// (OWNERSHIP-PRINCIPLES.md "Clients are projections"). The visible transcript
/// is `mirror.tail` followed by `log.entries`; older history is paged from the
/// owner on demand and never kept here.
@Observable @MainActor
final class HomeConversationSession {
    enum Change {
        /// Confirmed messages appended at the end (after the previous tail).
        case appended([ConversationMessage])
        case updated(ConversationMessage)
        /// A send was added, acknowledged, settled into a confirmed message, or failed.
        case pendingChanged
        case typing(Set<String>)
        /// The mirror was replaced (a gap or a reconnect): reload from the tail.
        case reset
    }

    let id: String
    private(set) var mirror: ConversationMirror?
    private(set) var log = ConversationIntentLog()
    /// Participants typing now (ephemeral, from `conversation-typing`).
    private(set) var typing: Set<String> = []
    /// Observers by token (each window showing this conversation has one).
    @ObservationIgnored private var observers: [UInt64: (Change) -> Void] = [:]
    @ObservationIgnored private var nextObserver: UInt64 = 0
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")

    init(id: String) {
        self.id = id
    }

    /// Adds an observer; returns the token that removes it.
    func observe(_ handler: @escaping (Change) -> Void) -> UInt64 {
        nextObserver += 1
        observers[nextObserver] = handler
        return nextObserver
    }

    func removeObserver(_ token: UInt64) {
        observers[token] = nil
    }

    private func emit(_ change: Change) {
        for observer in observers.values { observer(change) }
    }

    /// Fetches the snapshot (first open, a gap, a reconnect). Events that
    /// arrive meanwhile with a revision at or below the snapshot are stale.
    func load(from connection: DaemonConnection, tail: Int = 200, then resend: (@MainActor () -> Void)? = nil) {
        loading?.cancel()
        let id = id
        // task-owner: one conversation-snapshot read; ends with its reply
        loading = Task { [weak self] in
            do {
                let snapshot = try await connection.conversationSnapshot(id, tail: tail)
                guard let self, !Task.isCancelled else { return }
                if mirror == nil { mirror = ConversationMirror(snapshot: snapshot) } else { mirror?.reset(snapshot) }
                if let mirror { log.settle(against: mirror) }
                emit(.reset)
                resend?()
            } catch {
                self?.logger.error("conversation-snapshot \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Applies one owner event. Returns false when it showed a gap (the
    /// caller reloads the snapshot).
    func apply(_ event: ConversationEvent) -> Bool {
        guard var current = mirror else { return true }
        let outcome = current.apply(event)
        mirror = current
        switch outcome {
        case .stale: return true
        case .gap: return false
        case .applied(let change):
            let settled = log.settle(against: current)
            switch change {
            case .message(let message): emit(.appended([message]))
            case .messageUpdated(let message): emit(.updated(message))
            default: break
            }
            if !settled.isEmpty { emit(.pendingChanged) }
            return true
        }
    }

    func setTyping(_ participant: String, on: Bool) {
        let before = typing
        if on { typing.insert(participant) } else { typing.remove(participant) }
        if typing != before { emit(.typing(typing)) }
    }

    // MARK: Intents

    func addPending(_ send: PendingConversationSend) {
        if log.add(send) { emit(.pendingChanged) }
    }

    func acknowledge(_ clientMsgID: String, result: ConversationOpResult) {
        // The reply is the owner's committed change: it may write the mirror
        // when it is the next revision, so the bubble never blinks out
        // between the reply and the event.
        if var current = mirror, current.apply(rev: result.rev, change: result.change) != .gap {
            mirror = current
            if case .message(let message) = result.change, !result.replayed { emit(.appended([message])) }
        }
        log.acknowledge(clientMsgID, rev: result.rev)
        if let mirror { log.settle(against: mirror) }
        emit(.pendingChanged)
    }

    func reject(_ clientMsgID: String, reason: String) {
        log.reject(clientMsgID, reason: reason)
        emit(.pendingChanged)
    }

    func retry(_ clientMsgID: String) -> PendingConversationSend? {
        defer { emit(.pendingChanged) }
        return log.retry(clientMsgID)
    }
}
