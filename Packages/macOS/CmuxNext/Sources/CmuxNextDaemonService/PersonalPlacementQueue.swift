import CmuxNextDaemon

/// One home session owns personal order across all windows. Keep the UI's
/// edits immediate, but plan each write after the previous write is applied.
@MainActor
public final class PersonalPlacementQueue {
    /// What one queued placement did. Only a failed write stops the
    /// placements queued after it: each plan reads current store order when
    /// it runs, so a skipped one (its window closed, a workspace went away)
    /// leaves nothing for a later plan to depend on.
    public enum Outcome: Sendable {
        case applied
        case skipped
        case failed
    }

    private var tail: Task<Bool, Never>?
    private var serial = 0

    public init() {}

    /// No placement is queued or running: every one enqueued so far has
    /// finished (applied, skipped or failed) and released its ticket.
    public var isIdle: Bool { tail == nil }

    /// Returns once every placement enqueued so far, and any enqueued while
    /// waiting, has finished. A write that must land after them (a group set
    /// on a workspace a queued placement still moves) waits here first.
    public func drained() async {
        while let tail { _ = await tail.value }
    }

    /// `failed` settles this placement's pending edit whenever it did not
    /// apply: skipped, failed, or stopped by an earlier failure.
    public func enqueue(on home: DaemonService, failed: @escaping @MainActor () -> Void,
                        operation: @escaping @MainActor () async -> Outcome) {
        let previous = tail
        serial += 1
        let own = serial
        // Open before the task waits: a CLI action is not done while queued.
        let ticket = home.openTicket("queued personal placement")
        // task-owner: one queued placement; releases its ticket on every outcome
        tail = Task { [weak self] in
            let prior = await previous?.value ?? true
            let outcome: Outcome = prior && !Task.isCancelled ? await operation() : .failed
            if outcome != .applied { failed() }
            await home.closeTicket(ticket, label: "queued personal placement",
                                   error: outcome == .failed ? DaemonError.notConnected : nil)
            if self?.serial == own { self?.tail = nil }
            return outcome != .failed
        }
    }
}
