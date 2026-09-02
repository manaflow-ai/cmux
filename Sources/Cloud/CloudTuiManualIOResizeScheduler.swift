import Foundation

/// A cell grid sampled from the native Ghostty pane.
struct CloudTuiManualIOGrid: Equatable, Sendable {
    let columns: Int
    let rows: Int

    /// Creates a bounded, usable terminal grid.
    init?(columns: Int, rows: Int) {
        guard (2...10_000).contains(columns), (2...10_000).contains(rows) else {
            return nil
        }
        self.columns = columns
        self.rows = rows
    }
}

/// Coalesces pane resize samples while one remote resize request is in flight.
///
/// A divider drag can produce dozens of local Ghostty grid samples while a
/// cloud socket takes a round trip to acknowledge each request. Sending every
/// sample queues stale `SIGWINCH` work on the remote PTY and can leave the
/// terminal visibly behind the pane. This latest-wins state machine keeps one
/// request in flight and retains only the newest desired grid.
struct CloudTuiManualIOResizeScheduler: Equatable, Sendable {
    private(set) var desired: CloudTuiManualIOGrid? = nil
    private(set) var inFlight: CloudTuiManualIOGrid? = nil
    private(set) var lastAcknowledged: CloudTuiManualIOGrid? = nil

    /// Records a sample and returns a grid that may be sent immediately.
    mutating func sample(
        _ grid: CloudTuiManualIOGrid,
        canSend: Bool
    ) -> CloudTuiManualIOGrid? {
        desired = grid
        return beginIfPossible(canSend: canSend)
    }

    /// Completes the current request and optionally starts the newest pending
    /// request. When `canSend` is false (for example while geometry authority
    /// is being claimed), the newest sample remains parked in `desired`.
    mutating func acknowledge(canSend: Bool) -> CloudTuiManualIOGrid? {
        if let inFlight {
            lastAcknowledged = inFlight
        }
        self.inFlight = nil
        return beginIfPossible(canSend: canSend)
    }

    /// Resumes a parked sample after the connection becomes authoritative.
    mutating func resume() -> CloudTuiManualIOGrid? {
        beginIfPossible(canSend: true)
    }

    /// Forces the desired grid to be sent again, even when it matches the last
    /// acknowledged request. Used after a server replay reports a clamped or
    /// otherwise different authoritative grid.
    mutating func force(_ grid: CloudTuiManualIOGrid) -> CloudTuiManualIOGrid? {
        desired = grid
        lastAcknowledged = nil
        return beginIfPossible(canSend: true)
    }

    /// Retires the current request on reconnect while retaining the latest
    /// local sample for the new attachment.
    mutating func resetForReconnect() {
        inFlight = nil
        lastAcknowledged = nil
    }

    private mutating func beginIfPossible(canSend: Bool) -> CloudTuiManualIOGrid? {
        guard canSend, inFlight == nil, let desired else { return nil }
        guard desired != lastAcknowledged else { return nil }
        inFlight = desired
        return desired
    }
}
