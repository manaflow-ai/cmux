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
        /// The owner refused it, or it got no answer after every resend
        /// (`indeterminate`, `ownerUnreachable`). Sends stay visible as "Not
        /// Delivered" until the user retries or discards. A retry of an
        /// unanswered send keeps its key (the owner may have committed it);
        /// a retry of a refused send with attachments takes a new key.
        case failed(HomeRejection)
    }

    /// Replaced only before a send first reaches the owner (its parts adopt
    /// the owner's stored attachment records); the key never changes.
    public internal(set) var intent: HomeIntent
    public var state: State
    /// Set once the intent was resent without waiting for a reconnect.
    public var resentImmediately = false
    /// A send still uploading its attachments: not sent to the owner yet,
    /// so a disconnect or reconnect never resends it.
    public var isUploading = false
    /// A send waiting for an earlier send in its conversation to reach the
    /// owner first: not sent yet, so a disconnect or reconnect never
    /// resends it.
    public var isQueued = false
    /// A failed send that reached the owner and got no answer after every
    /// resend: the owner may have committed it.
    public var mayHaveBeenDelivered = false

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

    /// A send the client's cache kept across a relaunch: unconfirmed (resent
    /// under its key at the first connection), or Not Delivered when it had
    /// failed (the owner may have committed it, so a retry keeps the key).
    mutating func restore(_ intent: HomeIntent, failed: Bool) {
        guard !entries.contains(where: { $0.intent.key == intent.key }) else { return }
        var entry = PendingIntent(intent: intent, state: failed ? .failed(.indeterminate) : .unconfirmed)
        entry.mayHaveBeenDelivered = failed
        entries.append(entry)
    }

    public mutating func acknowledge(_ key: IdempotencyKey, rev: Revision) {
        update(key) { $0.state = .acknowledged(rev: rev) }
    }

    /// `mayHaveBeenDelivered`: no answer came, after the send itself went
    /// to the owner; false for a refusal.
    public mutating func fail(_ key: IdempotencyKey, _ rejection: HomeRejection, mayHaveBeenDelivered: Bool = false) {
        update(key) {
            $0.state = .failed(rejection)
            $0.mayHaveBeenDelivered = mayHaveBeenDelivered
        }
    }

    /// The uploads of a send finished (`uploading: false`) or a failed send
    /// uploads again with the same key (`uploading: true`, back to `.sending`).
    public mutating func setUploading(_ key: IdempotencyKey, _ uploading: Bool) {
        update(key) {
            $0.isUploading = uploading
            if uploading {
                $0.state = .sending
                $0.mayHaveBeenDelivered = false
            }
        }
    }

    /// Replaces the op of a send that has not reached the owner yet (same
    /// key, same position). False when the key is not in the log.
    @discardableResult
    public mutating func replaceOp(_ key: IdempotencyKey, with op: HomeOp) -> Bool {
        guard let index = entries.firstIndex(where: { $0.intent.key == key }) else { return false }
        let old = entries[index].intent
        entries[index].intent = HomeIntent(key: key, op: op, issuedAt: old.issuedAt)
        return true
    }

    /// Gives a refused send a new key in the same position, uploading again
    /// (the owner's ledger keeps the refused key, so the same key would get
    /// the same refusal). The row's id changes with the key.
    public mutating func rekey(_ key: IdempotencyKey, to newKey: IdempotencyKey) {
        guard let index = entries.firstIndex(where: { $0.intent.key == key }),
              !entries.contains(where: { $0.intent.key == newKey }) else { return }
        let old = entries[index].intent
        var entry = PendingIntent(intent: HomeIntent(key: newKey, op: old.op, issuedAt: old.issuedAt))
        entry.isUploading = true
        entries[index] = entry
    }

    public mutating func setQueued(_ key: IdempotencyKey, _ queued: Bool) {
        update(key) { $0.isQueued = queued }
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

    /// Takes one unconfirmed intent for a resend after a backoff delay.
    public mutating func takeResend(_ key: IdempotencyKey) -> HomeIntent? {
        guard let index = entries.firstIndex(where: { $0.intent.key == key }), entries[index].state == .unconfirmed else { return nil }
        entries[index].state = .sending
        return entries[index].intent
    }

    /// A failed intent the owner never decided goes out again with the
    /// same key (`.sending`, immediate resend allowed again).
    public mutating func revive(_ key: IdempotencyKey) {
        update(key) {
            $0.state = .sending
            $0.resentImmediately = false
            $0.mayHaveBeenDelivered = false
        }
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
        for index in entries.indices
        where entries[index].state == .sending && !entries[index].isUploading && !entries[index].isQueued {
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
