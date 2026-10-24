/// Runs one ``AcpmuxMailboxReader`` at a time for a main-actor owner and gives
/// it only the pages of the reader that is current.
///
/// A page reaches the main actor through a hop after the reader read it off
/// the main actor. The owner can stop or replace the reader in that hop (a
/// sign-out, another account): cancelling the reader's task does not stop a
/// page already on its way. The subscription numbers each reader, and a page
/// whose reader is no longer current is dropped on the main actor, where the
/// owner's own reset runs, so no page of a stopped reader is applied after
/// the reset (another person's reports never show).
///
/// ```swift
/// private let reports = AcpmuxMailboxSubscription()
/// reports.start(reader) { [weak self] page in self?.apply(page) }
/// reports.stop() // sign-out: no later page of that reader is applied
/// ```
@MainActor
public final class AcpmuxMailboxSubscription {
    /// The current reader's number; ``stop()`` and ``start(_:deliver:)`` move it on.
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    public init() {}

    /// Whether a reader runs.
    public var isRunning: Bool { task != nil }

    /// Stops the current reader, if any, and runs `reader`.
    ///
    /// - Parameters:
    ///   - reader: The reader to run.
    ///   - deliver: Gets each page of `reader` on the main actor, while `reader` is current.
    /// - Returns: The reader's task (tests await its end).
    @discardableResult
    public func start(_ reader: AcpmuxMailboxReader,
                      deliver: @escaping @MainActor @Sendable (AcpmuxMailboxPage) -> Void) -> Task<Void, Never> {
        stop()
        let current = generation
        let gated: @MainActor @Sendable (AcpmuxMailboxPage) -> Void = { [weak self] page in
            guard let self, self.generation == current else { return }
            deliver(page)
        }
        // task-owner: AcpmuxMailboxSubscription.task: the current reader; ended by stop() or the next start.
        let task = Task { await reader.run(deliver: gated) }
        self.task = task
        return task
    }

    /// Stops the current reader. A page it read before is dropped, also one
    /// already on its way to the main actor.
    public func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
}
