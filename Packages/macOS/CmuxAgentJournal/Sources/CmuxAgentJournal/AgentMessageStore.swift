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

    private struct Record: Codable {
        enum Kind: String, Codable {
            case message
            case state
        }

        var kind: Kind
        var message: AgentMessage?
        var id: String?
        var state: AgentMessageDeliveryState?
        var at: Date?
        var via: String?
    }

    private let fileURL: URL?
    private let now: @Sendable () -> Date
    private let makeId: @Sendable () -> String
    private let onChange: (@Sendable (AgentMessageStoreChange) -> Void)?

    // Lock justification: socket handlers call in synchronously from worker
    // threads and need the stored message back in the same call; every
    // guarded section is in-memory bookkeeping plus at most one line append.
    private let lock = NSLock()
    private var messagesById: [String: AgentMessage] = [:]
    private var order: [String] = []
    private var recordsSinceCompaction = 0
    /// The poller that owns each recipient surface's inbox. In memory only:
    /// after a restart the first poller to check in adopts the surface.
    private var pollerBySurface: [String: String] = [:]

    /// Opens the store at `fileURL`, or an in-memory store when `nil`.
    public init(
        fileURL: URL?,
        now: @escaping @Sendable () -> Date = { Date() },
        makeId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        onChange: (@Sendable (AgentMessageStoreChange) -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.now = now
        self.makeId = makeId
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
    /// on disk. Throws ``AgentMessageValidationError`` for a bad draft and
    /// ``AgentMessagePersistenceError`` when the record can't be written.
    @discardableResult
    public func append(_ draft: AgentMessageDraft) throws -> AgentMessage {
        let draft = try draft.validated()
        let message = try lock.withLock {
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
    /// them, oldest first.
    @discardableResult
    public func claimQueued(recipientSurfaceId: String, via: String) -> [AgentMessage] {
        let claimed = advance(
            where: { $0.recipientSurfaceId == recipientSurfaceId && $0.state == .queued },
            to: .delivered,
            via: via
        )
        return claimed
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

    /// Returns queued messages for the recipient when the poller still owns it.
    /// A superseded poller gets `nil` so it cannot wake the same surface after
    /// a newer hook has taken over.
    public func deferredMessages(
        recipientSurfaceId: String,
        pollerKey: String,
        limit: Int = 100
    ) -> [AgentMessage]? {
        lock.lock()
        defer { lock.unlock() }
        guard pollerBySurface[recipientSurfaceId] == pollerKey else { return nil }
        var result: [AgentMessage] = []
        for id in order {
            guard result.count < max(limit, 0) else { break }
            guard let message = messagesById[id],
                  message.recipientSurfaceId == recipientSurfaceId,
                  message.state == .queued else { continue }
            result.append(message)
        }
        return result
    }

    // MARK: - Polling

    /// A hook's inbox check. `register` makes `pollerKey` the surface's owner,
    /// superseding any older poller; hooks register once when they start.
    /// Later checks from any other key report ``AgentMessagePollOutcome/superseded``,
    /// so an agent that starts a new hook every turn never has more than one
    /// claiming messages.
    public func poll(recipientSurfaceId: String, pollerKey: String, register: Bool) -> AgentMessagePollOutcome {
        lock.lock()
        defer { lock.unlock() }
        if register {
            pollerBySurface[recipientSurfaceId] = pollerKey
        } else if let owner = pollerBySurface[recipientSurfaceId], owner != pollerKey {
            return .superseded
        } else {
            pollerBySurface[recipientSurfaceId] = pollerKey
        }
        let queued = messagesById.values.filter {
            $0.recipientSurfaceId == recipientSurfaceId && $0.state == .queued
        }.count
        return .current(queued: queued)
    }

    // MARK: - Private

    private func advance(
        where matches: (AgentMessage) -> Bool,
        to state: AgentMessageDeliveryState,
        via: String?
    ) -> [AgentMessage] {
        var changed: [AgentMessage] = []
        lock.lock()
        let at = now()
        for id in order {
            guard var message = messagesById[id],
                  matches(message),
                  message.state.canAdvance(to: state) else { continue }
            Self.apply(state: state, at: at, via: via, to: &message)
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
        for message in changed {
            onChange?(AgentMessageStoreChange(message: message, state: state))
        }
        return changed
    }

    private static func apply(
        state: AgentMessageDeliveryState,
        at: Date,
        via: String?,
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
        }
        message.state = state
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    /// Appends one JSON line to the journal, creating the file when it doesn't
    /// exist. A failed write is truncated back off the file so a partial line
    /// can't swallow the next record. In-memory stores write nothing.
    /// Must hold `lock`.
    private func appendRecord(_ record: Record) throws {
        guard let fileURL else { return }
        var data = try Self.encoder.encode(record)
        data.append(0x0A)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            // Never fall back to rewriting an existing file: a failed open
            // (out of descriptors, permissions) fails this write, not history.
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            let offset = try handle.seekToEnd()
            do {
                try handle.write(contentsOf: data)
            } catch {
                try? handle.truncate(atOffset: offset)
                throw error
            }
        } else {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    private func load(from fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let record = try? Self.decoder.decode(Record.self, from: Data(line)) else { continue }
            switch record.kind {
            case .message:
                guard let message = record.message, messagesById[message.id] == nil else { continue }
                messagesById[message.id] = message
                order.append(message.id)
            case .state:
                guard let id = record.id,
                      let state = record.state,
                      var message = messagesById[id],
                      message.state.canAdvance(to: state) else { continue }
                Self.apply(state: state, at: record.at ?? message.createdAt, via: record.via, to: &message)
                messagesById[id] = message
            }
        }
        if order.count > Self.compactionThreshold {
            compact(to: fileURL)
        }
    }

    /// Rewrites the file with the newest retained read messages and every
    /// queued or delivered message in their current state. The in-memory
    /// state changes only after the atomic file write succeeds.
    private func compact(to fileURL: URL) {
        let excess = max(order.count - Self.retainedMessageCount, 0)
        guard excess > 0 else {
            recordsSinceCompaction = 0
            return
        }
        var remaining = excess
        var kept: [String] = []
        kept.reserveCapacity(order.count)
        for id in order {
            if remaining > 0, let message = messagesById[id], message.state == .read {
                remaining -= 1
                continue
            }
            kept.append(id)
        }
        var data = Data()
        for id in kept {
            guard let message = messagesById[id],
                  let line = try? Self.encoder.encode(Record(kind: .message, message: message)) else {
                return
            }
            data.append(line)
            data.append(0x0A)
        }
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        let keptIDs = Set(kept)
        for id in order where !keptIDs.contains(id) {
            messagesById.removeValue(forKey: id)
        }
        order = kept
        recordsSinceCompaction = 0
    }
}
