public import CmuxHomeCore
public import Foundation

/// Turns a brain has handed out a stream for but not started yet.
///
/// A brain's `run` is synchronous and starts its turn on another task, so a
/// Stop can arrive before the turn exists anywhere a brain could find it.
/// `run` registers the turn here before it returns; ``stop(conversation:)``
/// marks every registered turn of the conversation, and the code that starts
/// the turn calls ``claim(_:)`` first and drops a stopped one.
///
/// ```swift
/// pending.register(token, conversation: id)   // in run, before returning
/// pending.stop(conversation: id)               // in interrupt, before routing
/// guard pending.claim(token) else { … }        // where the turn starts
/// ```
public final class ChiefPendingTurns: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UUID: (conversation: ConversationID, stopped: Bool)] = [:]

    /// Creates an empty registry.
    public init() {}

    /// Records turn `token` of `conversation` as handed out and not started.
    public func register(_ token: UUID, conversation: ConversationID) {
        lock.withLock { pending[token] = (conversation, false) }
    }

    /// Marks every unstarted turn of `conversation` as stopped.
    public func stop(conversation: ConversationID) {
        lock.withLock {
            for (token, entry) in pending where entry.conversation == conversation {
                pending[token] = (entry.conversation, true)
            }
        }
    }

    /// Marks turn `token` as stopped if it has not started (its consumer went away).
    public func stop(_ token: UUID) {
        lock.withLock {
            guard let entry = pending[token] else { return }
            pending[token] = (entry.conversation, true)
        }
    }

    /// Takes turn `token` out of the registry.
    ///
    /// - Returns: Whether the turn may start: false when it was stopped
    ///   before it started, or when it was already claimed.
    public func claim(_ token: UUID) -> Bool {
        lock.withLock {
            guard let entry = pending.removeValue(forKey: token) else { return false }
            return !entry.stopped
        }
    }
}
