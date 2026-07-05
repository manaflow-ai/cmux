import Foundation

struct AuthPhaseTimedOutState {
    let id: UUID
    /// Earliest time the gate may reopen once the timed-out work has finished.
    let expiresAt: UInt64
    /// Latest time the gate stays closed when the timed-out work never finishes.
    ///
    /// The token-touching path normally waits for the previous timed-out phase
    /// task to unwind before reopening (so a slow-but-honest cancellation does
    /// not start a second concurrent token operation). A Stack SDK call that
    /// hangs and ignores cancellation would never unwind, gating token
    /// acquisition for every session forever, so this hard deadline lets the
    /// gate reopen regardless (issue #6311). `nil` keeps the previous
    /// completion-only behavior for callers (e.g. ``AuthPhaseTimeoutRegistry``)
    /// that already reopen unconditionally after `expiresAt`.
    let hardExpiresAt: UInt64?

    init(id: UUID, expiresAt: UInt64, hardExpiresAt: UInt64? = nil) {
        self.id = id
        self.expiresAt = expiresAt
        self.hardExpiresAt = hardExpiresAt
    }
}
