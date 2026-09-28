public import Foundation

/// What happened to a message, reported to the store's change handler.
public struct AgentMessageStoreChange: Sendable, Equatable {
    public let message: AgentMessage
    /// The state the message just entered.
    public let state: AgentMessageDeliveryState
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
/// the newest ``retainedMessageCount`` messages when it grows past
/// ``compactionThreshold``. Records that fail to decode are skipped, so a torn
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
    @discardableResult
    public func append(_ draft: AgentMessageDraft) throws -> AgentMessage {
        let draft = try draft.validated()
        let message: AgentMessage
        lock.lock()
        let id = makeId()
        let parent = draft.inReplyTo.flatMap { messagesById[$0] }
        message = AgentMessage(
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
        messagesById[id] = message
        order.append(id)
        appendRecord(Record(kind: .message, message: message))
        lock.unlock()

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

    /// Marks the recipient's delivered messages read. Called when the
    /// recipient finishes a turn after delivery.
    @discardableResult
    public func markDeliveredRead(recipientSurfaceId: String) -> [AgentMessage] {
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
            appendRecord(Record(kind: .state, id: id, state: state, at: at, via: via))
            changed.append(message)
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

    /// Must hold `lock`.
    private func appendRecord(_ record: Record) {
        guard let fileURL, var data = try? Self.encoder.encode(record) else { return }
        data.append(0x0A)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            // Never fall back to rewriting an existing file: a failed open
            // (out of descriptors, permissions) loses one record, not history.
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: fileURL, options: .atomic)
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

    /// Rewrites the file with the newest retained messages in their current
    /// state. Runs during init, before the store is shared.
    private func compact(to fileURL: URL) {
        let dropped = order.prefix(order.count - Self.retainedMessageCount)
        for id in dropped {
            messagesById.removeValue(forKey: id)
        }
        order.removeFirst(dropped.count)
        var data = Data()
        for id in order {
            guard let message = messagesById[id],
                  let line = try? Self.encoder.encode(Record(kind: .message, message: message)) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
