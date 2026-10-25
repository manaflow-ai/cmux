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
/// The write blocks this actor's pool thread for one small file: the stores are made before the
/// app's `BackgroundWork` exists, and one actor per file serializes its writes, so at most one pool
/// thread per file waits on the disk.
actor AgentPaneStateFile<Value: Encodable & Sendable> {
    /// The file.
    nonisolated let url: URL
    private let writer: any AgentPaneStateFileWriting
    /// The newest state written; an older one is dropped.
    private var written: UInt64 = 0

    /// - Parameters:
    ///   - url: the file.
    ///   - writer: where its bytes go (the disk, or a test's recorder).
    init(url: URL, writer: any AgentPaneStateFileWriting) {
        self.url = url
        self.writer = writer
    }

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
