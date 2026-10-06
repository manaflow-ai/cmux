public import Foundation

/// What happened to a message, reported to the store's change handler.
public struct AgentMessageStoreChange: Sendable, Equatable {
    public let message: AgentMessage
    /// The state the message just entered.
    public let state: AgentMessageDeliveryState
}

/// The store could not write a new message to its journal file. The message
/// was not stored: nothing in memory changed and no change was published.
public struct AgentMessagePersistenceError: Error, Equatable, Sendable {
    /// Description of the underlying file error.
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// Result of a hook's inbox check for its surface.
public enum AgentMessagePollOutcome: Sendable, Equatable {
    /// The poller owns the surface's inbox. `queued` messages are waiting;
    /// nothing is claimed, so the poller claims when it is ready to deliver.
    case current(queued: Int)
    /// A newer poller registered for the surface; this one should stop.
    case superseded
}

/// A short-lived reservation of queued messages for a Claude wake hook.
public struct AgentMessageDeferredLease: Sendable, Equatable {
    /// Opaque token required to acknowledge the wake delivery.
    public let id: String
    /// Messages reserved by the wake hook, oldest first.
    public let messages: [AgentMessage]

    public init(id: String, messages: [AgentMessage]) {
        self.id = id
        self.messages = messages
    }
}

/// Durable inbox of agent messages, keyed by recipient surface.
///
/// Storage is an append-only JSON Lines file: one record per new message and
/// one per state change. The file is replayed on open and rewritten with only
/// the newest ``retainedMessageCount`` read messages and all undelivered
/// messages when it grows past ``compactionThreshold``. Records that fail to
/// decode are skipped, so a torn
/// final line after a crash loses at most that record.
///
/// Concurrency: callers are socket handlers on arbitrary threads, so every
/// method is synchronous and serialized by one lock around in-memory state and
/// a short file append. Nothing waits inside the store: hooks poll with
/// ``poll(recipientSurfaceId:pollerKey:register:)`` over short-lived socket
/// connections, so an idle agent never holds a connection open.
///
/// ```swift
/// let store = AgentMessageStore(fileURL: url)
/// let message = try store.append(draft)
/// let delivered = store.claimQueued(recipientSurfaceId: surface, via: "claude.wake")
/// ```
public final class AgentMessageStore: @unchecked Sendable {
    public static let retainedMessageCount = 2_000
    public static let compactionThreshold = 2_500
    public static let deferredLeaseLifetime: TimeInterval = 30
    /// Most opt-outs kept. Past it the oldest is dropped; that is almost
    /// always a surface or workspace that has since closed.
    public static let retainedOptOutCount = 1_000

    struct Record: Codable {
        enum Kind: String, Codable {
            case message
            case state
            /// A surface or workspace turned messages off (`enabled` false)
            /// or back on.
            case recipient
        }

        var kind: Kind
        var message: AgentMessage?
        var id: String?
        var state: AgentMessageDeliveryState?
        var at: Date?
        var via: String?
        /// Failure reason code for a `failed` state record.
        var reason: String?
        var scope: AgentMessageRecipientScope?
        var enabled: Bool?
    }

    struct DeferredLease {
        let surfaceId: String
        let pollerKey: String
        let messageIDs: [String]
        let expiresAt: Date
    }

    let fileURL: URL?
    let now: @Sendable () -> Date
    private let makeId: @Sendable () -> String
    let onChange: (@Sendable (AgentMessageStoreChange) -> Void)?
    /// The app-wide switch (`agentMessages.enabled`), read on every send and
    /// delivery so turning it off takes effect at once.
    let isEnabled: @Sendable () -> Bool

    // Lock justification: socket handlers call in synchronously from worker
    // threads and need the stored message back in the same call; every
    // guarded section is in-memory bookkeeping plus at most one line append.
    let lock = NSLock()
    var messagesById: [String: AgentMessage] = [:]
    var order: [String] = []
    var recordsSinceCompaction = 0
    /// The poller that owns each recipient surface's inbox. In memory only:
    /// after a restart the first poller to check in adopts the surface.
    private var pollerBySurface: [String: String] = [:]
    /// Queued messages handed to a wake hook stay reserved until the hook
    /// acknowledges its short-lived lease or the lease expires.
    var deferredLeases: [String: DeferredLease] = [:]
    /// Surfaces and workspaces that turned messages off, oldest first in
    /// `optOutOrder` and capped at ``retainedOptOutCount``. Persisted in the
    /// journal as `recipient` records.
    var disabledSurfaceIds: Set<String> = []
    var disabledWorkspaceIds: Set<String> = []
    var optOutOrder: [AgentMessageOptOut] = []
    /// Runs just before a delivery takes the lock, so tests can turn a switch
    /// off at the last moment.
    var beforeDeliveryLockForTesting: (@Sendable () -> Void)?

    /// Opens the store at `fileURL`, or an in-memory store when `nil`.
    /// `isEnabled` is the app-wide switch; while it returns false nothing is
    /// accepted or delivered.
    public init(
        fileURL: URL?,
        now: @escaping @Sendable () -> Date = { Date() },
        makeId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        isEnabled: @escaping @Sendable () -> Bool = { true },
        onChange: (@Sendable (AgentMessageStoreChange) -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.now = now
        self.makeId = makeId
        self.isEnabled = isEnabled
        self.onChange = onChange
        if let fileURL {
            load(from: fileURL)
        }
    }

    // MARK: - Writes

    /// Validates and stores a new queued message.
    ///
    /// The journal write is the source of truth: the message joins the
    /// in-memory inbox and the change handler fires only after its record is
    /// on disk. Throws ``AgentMessageValidationError`` for a bad draft,
    /// ``AgentMessageBlockedError`` when messages are off for the recipient,
    /// and ``AgentMessagePersistenceError`` when the record can't be written.
    @discardableResult
    public func append(_ draft: AgentMessageDraft) throws -> AgentMessage {
        let draft = try draft.validated()
        let message = try lock.withLock {
            if let block = blockLocked(
                recipientSurfaceId: draft.recipientSurfaceId,
                recipientWorkspaceId: draft.recipientWorkspaceId
            ) {
                throw AgentMessageBlockedError(block: block)
            }
            let id = makeId()
            let parent = draft.inReplyTo.flatMap { messagesById[$0] }
            let message = AgentMessage(
                id: id,
                threadId: draft.threadId ?? parent?.threadId ?? id,
                senderName: draft.senderName,
                senderSurfaceId: draft.senderSurfaceId,
                senderWorkspaceId: draft.senderWorkspaceId,
                recipientSurfaceId: draft.recipientSurfaceId,
                recipientWorkspaceId: draft.recipientWorkspaceId,
                body: draft.body,
                createdAt: now(),
                inReplyTo: draft.inReplyTo
            )
            do {
                try appendRecord(Record(kind: .message, message: message))
            } catch {
                throw AgentMessagePersistenceError(reason: String(describing: error))
            }
            messagesById[id] = message
            order.append(id)
            recordsSinceCompaction += 1
            if let fileURL,
               order.count > Self.compactionThreshold,
               recordsSinceCompaction >= Self.compactionThreshold {
                compact(to: fileURL)
            }
            return message
        }
        onChange?(AgentMessageStoreChange(message: message, state: .queued))
        return message
    }

    /// Marks every queued message for the recipient delivered and returns
    /// them, oldest first. A message whose recipient is blocked fails
    /// instead, decided under the same lock that delivers it.
    @discardableResult
    public func claimQueued(recipientSurfaceId: String, via: String) -> [AgentMessage] {
        beforeDeliveryLockForTesting?()
        return advance(
            where: {
                $0.recipientSurfaceId == recipientSurfaceId
                    && $0.state == .queued
                    && !isDeferredMessageReserved($0.id)
            },
            to: .delivered,
            via: via,
            failingBlocked: true
        )
    }

    /// Acknowledges a wake hook after it has written its rendered messages to
    /// stderr. The lease owner may acknowledge after a newer poller replaces
    /// it; an expired or unknown lease is ignored.
    @discardableResult
    public func acknowledgeDeferredLease(
        id leaseID: String,
        recipientSurfaceId: String,
        pollerKey: String,
        via: String
    ) -> [AgentMessage] {
        lock.lock()
        pruneExpiredDeferredLeases()
        guard let lease = deferredLeases[leaseID],
              lease.surfaceId == recipientSurfaceId,
              lease.pollerKey == pollerKey else {
            lock.unlock()
            return []
        }
        let messageIDs = Set(lease.messageIDs)
        lock.unlock()
        let delivered = advance(
            where: { messageIDs.contains($0.id) && $0.recipientSurfaceId == recipientSurfaceId },
            to: .delivered,
            via: via,
            allowDeferredLease: true
        )
        lock.lock()
        deferredLeases.removeValue(forKey: leaseID)
        lock.unlock()
        return delivered
    }

    /// Marks the given messages read. Unknown ids and messages already read
    /// are ignored.
    @discardableResult
    public func markRead(ids: [String]) -> [AgentMessage] {
        let wanted = Set(ids)
        return advance(where: { wanted.contains($0.id) }, to: .read, via: nil)
    }

    /// Marks the recipient's queued and delivered messages read. Called when
    /// the recipient or a human confirms the inbox contents.
    @discardableResult
    public func markDeliveredRead(recipientSurfaceId: String) -> [AgentMessage] {
        advance(
            where: {
                $0.recipientSurfaceId == recipientSurfaceId
                    && ($0.state == .queued || $0.state == .delivered)
            },
            to: .read,
            via: nil
        )
    }

    /// Marks only messages that were already delivered read. Hook delivery
    /// uses this before claiming newly queued messages.
    @discardableResult
    public func markPreviouslyDeliveredRead(recipientSurfaceId: String) -> [AgentMessage] {
        advance(
            where: { $0.recipientSurfaceId == recipientSurfaceId && $0.state == .delivered },
            to: .read,
            via: nil
        )
    }

    // MARK: - Reads

    public func message(id: String) -> AgentMessage? {
        lock.lock()
        defer { lock.unlock() }
        return messagesById[id]
    }

    public func hasQueued(recipientSurfaceId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return messagesById.values.contains {
            $0.recipientSurfaceId == recipientSurfaceId && $0.state == .queued
        }
    }

    /// Messages newest first, optionally filtered by recipient or sender
    /// surface and state.
    public func messages(
        surfaceId: String? = nil,
        states: Set<AgentMessageDeliveryState>? = nil,
        limit: Int = 100
    ) -> [AgentMessage] {
        lock.lock()
        defer { lock.unlock() }
        var result: [AgentMessage] = []
        for id in order.reversed() {
            guard result.count < max(limit, 0) else { break }
            guard let message = messagesById[id] else { continue }
            if let surfaceId,
               message.recipientSurfaceId != surfaceId,
               message.senderSurfaceId != surfaceId {
                continue
            }
            if let states, !states.contains(message.state) { continue }
            result.append(message)
        }
        return result
    }

    /// Returns and reserves queued messages for the recipient when the poller
    /// still owns it. A superseded poller gets `nil` so it cannot wake the same
    /// surface after a newer hook has taken over. Reservations keep a
    /// concurrent prompt hook from claiming the same messages after this wake
    /// has rendered them. A message whose recipient is blocked fails instead
    /// of joining the lease, decided under the lock that builds the lease.
    public func deferredMessages(
        recipientSurfaceId: String,
        pollerKey: String,
        limit: Int = 100
    ) -> AgentMessageDeferredLease? {
        beforeDeliveryLockForTesting?()
        var failed: [AgentMessage] = []
        defer { publish(failed, as: .failed) }
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredDeferredLeases()
        guard pollerBySurface[recipientSurfaceId] == pollerKey else { return nil }
        let reserved = Set(deferredLeases.values.filter { $0.surfaceId == recipientSurfaceId }.flatMap(\.messageIDs))
        var result: [AgentMessage] = []
        for id in order {
            guard result.count < max(limit, 0) else { break }
            guard let message = messagesById[id],
                  message.recipientSurfaceId == recipientSurfaceId,
                  message.state == .queued,
                  !reserved.contains(id) else { continue }
            if let block = blockLocked(recipientSurfaceId: message.recipientSurfaceId, recipientWorkspaceId: message.recipientWorkspaceId) {
                failed.append(failLocked(id: id, block: block, at: now()))
                continue
            }
            result.append(message)
        }
        guard !result.isEmpty else {
            return AgentMessageDeferredLease(id: "", messages: [])
        }
        let leaseID = makeId()
        deferredLeases[leaseID] = DeferredLease(
            surfaceId: recipientSurfaceId,
            pollerKey: pollerKey,
            messageIDs: result.map(\.id),
            expiresAt: now().addingTimeInterval(Self.deferredLeaseLifetime)
        )
        return AgentMessageDeferredLease(id: leaseID, messages: result)
    }

    // MARK: - Polling

    /// A hook's inbox check. `register` makes `pollerKey` the surface's owner,
    /// superseding any older poller; hooks register once when they start.
    /// Later checks from any other key report ``AgentMessagePollOutcome/superseded``,
    /// so an agent that starts a new hook every turn never has more than one
    /// claiming messages.
    public func poll(recipientSurfaceId: String, pollerKey: String, register: Bool) -> AgentMessagePollOutcome {
        failBlockedQueued(recipientSurfaceId: recipientSurfaceId)
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredDeferredLeases()
        if register {
            pollerBySurface[recipientSurfaceId] = pollerKey
        } else if let owner = pollerBySurface[recipientSurfaceId], owner != pollerKey {
            return .superseded
        } else {
            pollerBySurface[recipientSurfaceId] = pollerKey
        }
        let queued = messagesById.values.filter {
            $0.recipientSurfaceId == recipientSurfaceId
                && $0.state == .queued
                && !isDeferredMessageReserved($0.id)
        }.count
        return .current(queued: queued)
    }

    // MARK: - Private

    func advance(
        where matches: (AgentMessage) -> Bool,
        to state: AgentMessageDeliveryState,
        via: String?,
        allowDeferredLease: Bool = false,
        failingBlocked: Bool = false
    ) -> [AgentMessage] {
        var changed: [AgentMessage] = []
        var failed: [AgentMessage] = []
        lock.lock()
        pruneExpiredDeferredLeases()
        let at = now()
        for id in order {
            guard var message = messagesById[id],
                  matches(message),
                  (allowDeferredLease || !isDeferredMessageReserved(id)),
                  message.state.canAdvance(to: state) else { continue }
            if failingBlocked, let block = blockLocked(
                recipientSurfaceId: message.recipientSurfaceId,
                recipientWorkspaceId: message.recipientWorkspaceId
            ) {
                failed.append(failLocked(id: id, block: block, at: at))
                continue
            }
            Self.apply(state: state, at: at, via: via, reason: nil, to: &message)
            messagesById[id] = message
            // State records are best effort: if one is lost, a restart
            // replays the message in its earlier state, so a delivered
            // message can be delivered again but none is dropped.
            if (try? appendRecord(Record(kind: .state, id: id, state: state, at: at, via: via))) != nil {
                recordsSinceCompaction += 1
            }
            changed.append(message)
        }
        if let fileURL,
           order.count > Self.compactionThreshold,
           recordsSinceCompaction >= Self.compactionThreshold {
            compact(to: fileURL)
        }
        lock.unlock()
        publish(failed, as: .failed)
        publish(changed, as: state)
        return changed
    }

    func publish(_ messages: [AgentMessage], as state: AgentMessageDeliveryState) {
        for message in messages {
            onChange?(AgentMessageStoreChange(message: message, state: state))
        }
    }

    static func apply(
        state: AgentMessageDeliveryState,
        at: Date,
        via: String?,
        reason: String?,
        to message: inout AgentMessage
    ) {
        switch state {
        case .queued:
            break
        case .delivered:
            message.deliveredAt = at
            message.deliveredVia = via
        case .read:
            // A message a human reads before any agent delivery skips
            // straight to read; it is never delivered afterwards.
            message.readAt = at
        case .failed:
            message.failureReason = reason
        }
        message.state = state
    }

    func pruneExpiredDeferredLeases() {
        let current = now()
        deferredLeases = deferredLeases.filter { $0.value.expiresAt > current }
    }

    func isDeferredMessageReserved(_ messageID: String) -> Bool {
        deferredLeases.values.contains { $0.messageIDs.contains(messageID) }
    }
}
