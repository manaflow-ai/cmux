public import CmuxNextDaemon
import Foundation
public import Observation
import os

/// One open local conversation: the confirmed mirror (written only by the
/// owner's changes) plus the intent log of unconfirmed sends
/// (OWNERSHIP-PRINCIPLES.md "Clients are projections"). The visible transcript
/// is `mirror.tail` followed by `log.entries`; older history is paged from the
/// owner on demand and never kept here.
@Observable @MainActor
public final class HomeConversationSession {
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
    public private(set) var mirror: ConversationMirror?
    public private(set) var log = ConversationIntentLog()
    /// Participants typing now (ephemeral, from `conversation-typing`).
    public private(set) var typing: Set<String> = []
    /// Observers by token (each window showing this conversation has one).
    @ObservationIgnored private var observers: [UInt64: (Change) -> Void] = [:]
    @ObservationIgnored private var nextObserver: UInt64 = 0
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// Events that arrived while a snapshot was loading; applied after it when
    /// newer than the snapshot (so a change committed during the read is kept).
    @ObservationIgnored private var buffered: [ConversationEvent] = []
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")

    public init(id: String) {
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
    public func load(from connection: DaemonConnection, tail: Int = 200, then resend: (@MainActor () -> Void)? = nil) {
        loading?.cancel()
        isLoading = true
        let id = id
        // task-owner: one conversation-snapshot read; ends with its reply
        // main-hop-allow: the snapshot read awaits the daemon's actor; its resume resets the session's main-actor mirror and replays the events buffered meanwhile, in order, before any newer event applies
        loading = Task { [weak self] in
            do {
                let snapshot = try await ConversationClient(connection).snapshot(id, tail: tail)
                guard let self, !Task.isCancelled else { return }
                isLoading = false
                // Never move back to an older revision than the mirror already has.
                if mirror.map({ $0.rev <= snapshot.conversation.rev }) ?? true {
                    if mirror == nil { mirror = ConversationMirror(snapshot: snapshot) } else { mirror?.reset(snapshot) }
                    typing.removeAll()
                }
                let pending = buffered
                buffered.removeAll()
                for event in pending where event.rev > (mirror?.rev ?? 0) { _ = apply(event) }
                if let mirror { log.settle(against: mirror) }
                emit(.reset)
                resend?()
            } catch {
                self?.isLoading = false
                self?.buffered.removeAll()
                self?.logger.error("conversation-snapshot \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Applies one owner event. Returns false when it showed a gap (the
    /// caller reloads the snapshot).
    public func apply(_ event: ConversationEvent) -> Bool {
        if isLoading || mirror == nil {
            if buffered.count < 1024 { buffered.append(event) }
            return true
        }
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

    public func setTyping(_ participant: String, on: Bool) {
        let before = typing
        if on { typing.insert(participant) } else { typing.remove(participant) }
        if typing != before { emit(.typing(typing)) }
    }

    // MARK: Intents

    public func addPending(_ send: PendingConversationSend) {
        if log.add(send) { emit(.pendingChanged) }
    }

    /// The owner's reply settles the intent only; the mirror is written by the
    /// owner's events alone. The pending bubble stays until the mirror reaches
    /// the acknowledged revision, so it never blinks out or shows twice.
    public func acknowledge(_ clientMsgID: String, result: ConversationOpResult) {
        log.acknowledge(clientMsgID, rev: result.rev)
        if let mirror { log.settle(against: mirror) }
        emit(.pendingChanged)
    }

    public func reject(_ clientMsgID: String, reason: String) {
        log.reject(clientMsgID, reason: reason)
        emit(.pendingChanged)
    }

    public func retry(_ clientMsgID: String) -> PendingConversationSend? {
        defer { emit(.pendingChanged) }
        return log.retry(clientMsgID)
    }
}
