import Foundation

/// One intent the owner has not confirmed yet.
public struct PendingIntent: Hashable, Sendable, Identifiable {
    public enum State: Hashable, Sendable {
        /// Sent, no answer yet.
        case sending
        /// Sent before a disconnect; resent with the same key on reconnect.
        case unconfirmed
        /// The owner committed it at `rev` of the op's stream. It leaves the
        /// log when the mirror reaches that revision (or echoes the message).
        case acknowledged(rev: Revision)
        /// The owner refused it. Sends stay visible as "Not Delivered" until
        /// the user retries (a new key) or discards.
        case failed(HomeRejection)
    }

    public let intent: HomeIntent
    public var state: State
    /// Set once the intent was resent without waiting for a reconnect.
    public var resentImmediately = false

    public init(intent: HomeIntent, state: State = .sending) {
        self.intent = intent
        self.state = state
    }

    public var id: IdempotencyKey { intent.key }
}

/// The ordered log of the client's unconfirmed intents. The visible state is
/// mirror + this log; nothing else in the client is optimistic.
public struct IntentLog: Hashable, Sendable {
    public private(set) var entries: [PendingIntent] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// False when the key is already in the log (the same intent twice).
    @discardableResult
    public mutating func append(_ intent: HomeIntent) -> Bool {
        guard !entries.contains(where: { $0.intent.key == intent.key }) else { return false }
        entries.append(PendingIntent(intent: intent))
        return true
    }

    public mutating func acknowledge(_ key: IdempotencyKey, rev: Revision) {
        update(key) { $0.state = .acknowledged(rev: rev) }
    }

    public mutating func fail(_ key: IdempotencyKey, _ rejection: HomeRejection) {
        update(key) { $0.state = .failed(rejection) }
    }

    public mutating func discard(_ key: IdempotencyKey) {
        entries.removeAll { $0.intent.key == key }
    }

    /// One sent intent got no answer (`indeterminate`, or the owner became
    /// unreachable mid-flight): it is resent with the same key.
    public mutating func markUnconfirmed(_ key: IdempotencyKey) {
        update(key) { if $0.state == .sending { $0.state = .unconfirmed } }
    }

    /// Takes one unconfirmed intent for an immediate resend (the connection
    /// stayed up). At most once per intent; later resends wait for a reconnect.
    public mutating func takeImmediateResend(_ key: IdempotencyKey) -> HomeIntent? {
        guard let index = entries.firstIndex(where: { $0.intent.key == key }),
              entries[index].state == .unconfirmed, !entries[index].resentImmediately else { return nil }
        entries[index].state = .sending
        entries[index].resentImmediately = true
        return entries[index].intent
    }

    /// Drops intents whose conversation left the inbox. Returns their keys.
    @discardableResult
    public mutating func dropIntents(outside conversations: Set<ConversationID>) -> [IdempotencyKey] {
        var dropped: [IdempotencyKey] = []
        entries.removeAll { entry in
            guard let id = entry.intent.op.conversation, !conversations.contains(id) else { return false }
            dropped.append(entry.intent.key)
            return true
        }
        return dropped
    }

    /// On disconnect: everything still in flight becomes unconfirmed.
    public mutating func markDisconnected() {
        for index in entries.indices where entries[index].state == .sending {
            entries[index].state = .unconfirmed
        }
    }

    /// On reconnect: the intents to resend, in order, with their original keys.
    public mutating func takeResends() -> [HomeIntent] {
        var resends: [HomeIntent] = []
        for index in entries.indices where entries[index].state == .unconfirmed {
            entries[index].state = .sending
            resends.append(entries[index].intent)
        }
        return resends
    }

    /// Drops every intent the mirror now confirms. Returns the keys that left.
    @discardableResult
    public mutating func settle(against mirror: HomeMirror) -> [IdempotencyKey] {
        var settled: [IdempotencyKey] = []
        entries.removeAll { entry in
            let done = Self.isSettled(entry, by: mirror)
            if done { settled.append(entry.intent.key) }
            return done
        }
        return settled
    }

    static func isSettled(_ entry: PendingIntent, by mirror: HomeMirror) -> Bool {
        if case .sendMessage(let conversation, _) = entry.intent.op,
           mirror.message(clientID: entry.intent.key, in: conversation) != nil {
            return true
        }
        if case .acknowledged(let rev) = entry.state {
            let stream = entry.intent.op.stream
            return !mirror.isStale(stream) && mirror.revision(of: stream) >= rev
        }
        return false
    }

    /// Pending sends for one conversation, in the order the user made them.
    public func sends(in conversation: ConversationID) -> [PendingIntent] {
        entries.filter {
            if case .sendMessage(let target, _) = $0.intent.op { return target == conversation }
            return false
        }
    }

    private mutating func update(_ key: IdempotencyKey, _ change: (inout PendingIntent) -> Void) {
        guard let index = entries.firstIndex(where: { $0.intent.key == key }) else { return }
        change(&entries[index])
    }
}
