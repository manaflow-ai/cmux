import Foundation

/// One small JSON state file of the agent pane, written off the main actor in the order its owner
/// made the states: a Repository actor, one per file (the chats' scroll places, the new chats'
/// unsent drafts).
///
/// The owner, a main-actor store, numbers each state and hands it over with ``write(_:sequence:)``;
/// the actor encodes it and writes it, or removes the file for a nil state. A state that reaches
/// the actor after a newer one is dropped, since the newer one holds everything it does (the rule
/// `HomeCache` follows). Quit's flush is one more ``write(_:sequence:)`` of the owner's newest
/// state: written when it has not been yet, and in either case the call returns after every
/// earlier write that reached the actor.
///
/// The actor runs on its own serial dispatch queue (``unownedExecutor``), never on Swift's
/// cooperative pool: the write is blocking file I/O (threading-model.md: blocking work never runs
/// on the pool). Each file has its own queue, named and registered in threading-model.md's
/// "Registered threads and queues", which the owner makes with a literal label and passes in.
actor AgentPaneStateFile<Value: Encodable & Sendable> {
    /// The file.
    nonisolated let url: URL
    private let writer: any AgentPaneStateFileWriting
    /// The serial queue every job of this actor runs on (its executor).
    private nonisolated let queue: DispatchSerialQueue
    /// The newest state written; an older one is dropped.
    private var written: UInt64 = 0

    /// - Parameters:
    ///   - url: the file.
    ///   - writer: where its bytes go (the disk, or a test's recorder).
    ///   - queue: the actor's own serial queue, at `.utility` (a save nothing waits for but quit).
    init(url: URL, writer: any AgentPaneStateFileWriting, queue: DispatchSerialQueue) {
        self.url = url
        self.writer = writer
        self.queue = queue
    }

    /// The actor's jobs run on ``queue``, off the cooperative pool.
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Writes state `sequence` (nil removes the file) unless a state numbered `sequence` or later
    /// was written already.
    func write(_ value: Value?, sequence: UInt64) {
        guard sequence > written else { return }
        written = sequence
        guard let value else { return writer.remove(url) }
        guard let data = try? JSONEncoder().encode(value) else { return }
        writer.write(data, to: url)
    }
}
