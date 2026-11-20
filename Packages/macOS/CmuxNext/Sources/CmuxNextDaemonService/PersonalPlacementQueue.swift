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

    /// One placement's ticket, closed once: early by `releaseHeld`, else when the placement finishes.
    @MainActor private final class Hold {
        var ticket: CommandTicket?
        init(_ ticket: CommandTicket?) { self.ticket = ticket }
        func close(on home: DaemonService, error: (any Error)?) async {
            guard let ticket else { return }
            self.ticket = nil
            await home.closeTicket(ticket, label: "queued personal placement", error: error)
        }
    }

    private var tail: Task<Bool, Never>?
    /// The tickets of the placements queued or running, by serial.
    private var holds: [Int: Hold] = [:]
    /// A placement's write is being sent again: a placement queued now does not hold its action either.
    private var retrying = false
    private var serial = 0

    public init() {}

    /// The running placement's write went unanswered and is sent again in the background
    /// (`DaemonService.performUntilAnswered`): the queue still waits for it, but the actions awaiting it and every
    /// placement queued behind it, or queued until it ends, stop holding their action scope and read that the moves
    /// may still apply, so no script waits on retries.
    public func releaseHeld(on home: DaemonService) async {
        retrying = true
        let unanswered = DaemonError.timedOut("queued personal placement (sent again until answered)")
        for hold in holds.values { await hold.close(on: home, error: unanswered) }
    }

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
        let hold = Hold(home.openTicket("queued personal placement"))
        holds[own] = hold
        // task-owner: one queued placement; releases its ticket on every outcome
        tail = Task { [weak self] in
            if self?.retrying == true {
                await hold.close(on: home, error: DaemonError.timedOut("queued personal placement (behind one sent again until answered)"))
            }
            let prior = await previous?.value ?? true
            let outcome: Outcome = prior && !Task.isCancelled ? await operation() : .failed
            if outcome != .applied { failed() }
            await hold.close(on: home, error: outcome == .failed ? DaemonError.notConnected : nil)
            self?.holds[own] = nil
            self?.retrying = false
            if self?.serial == own { self?.tail = nil }
            return outcome != .failed
        }
    }
}
