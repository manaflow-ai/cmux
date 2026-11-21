/// The one chat open a person clicked while this Mac's sessions were not ready (``PendingSessionOpen``),
/// and what becomes of it. A newer click replaces it; it runs once the sessions are ready, and is dropped
/// when its window closed or after ``PendingOpenPatience/limit``. Pure (no windows, no clock of its own),
/// so the decision is tested alone.
struct PendingOpenSlot<Open> {
    enum Outcome {
        /// The sessions are ready: run it now.
        case run(Open)
        /// Its window closed, or it waited too long: drop it and say so once.
        case drop(Open)
    }

    private var open: Open?
    private var queuedAt: ContinuousClock.Instant?

    var isWaiting: Bool { open != nil }

    /// Keeps `open`, queued at `now`, in place of one already waiting (the newer click wins). True when
    /// it replaced one.
    @discardableResult
    mutating func hold(_ open: Open, at now: ContinuousClock.Instant) -> Bool {
        let replaced = self.open != nil
        self.open = open
        queuedAt = now
        return replaced
    }

    /// What the waiting open does now; nil while it keeps waiting (or none waits). A run or a drop
    /// empties the slot.
    mutating func step(ready: Bool, windowOpen: Bool, now: ContinuousClock.Instant) -> Outcome? {
        guard let open, let queuedAt else { return nil }
        let outcome: Outcome
        if !windowOpen {
            outcome = .drop(open)
        } else if ready {
            outcome = .run(open)
        } else if now - queuedAt >= PendingOpenPatience.limit {
            outcome = .drop(open)
        } else {
            return nil
        }
        self.open = nil
        self.queuedAt = nil
        return outcome
    }
}

extension PendingOpenSlot.Outcome: Equatable where Open: Equatable {}

/// How long a click waits for this Mac's sessions before it is dropped.
enum PendingOpenPatience {
    static let limit: Duration = .seconds(600)
}
