/// Audit-log sink used by every write path in
/// ``DefaultTerminalAccessService`` and the HTTP layer.
///
/// Per D4 the production wiring is ALWAYS-ON in v1 — Settings only
/// controls the log file path. ``NoOpAuditLog`` exists for tests only.
///
/// Per Errata E2 the `record` requirement is `async` and is **not
/// throwing**: a backing file write that fails is the audit log's
/// problem to handle (typically by buffering or surfacing through a
/// separate health metric), never the caller's problem to surface to
/// the HTTP client.
public protocol AuditLog: Sendable {
    /// Records one audit entry.
    ///
    /// Implementations must be safe to call from any task and must
    /// preserve ordering relative to the awaiting caller. Errors are
    /// swallowed inside the implementation; the call site simply
    /// `await`s.
    func record(_ entry: AuditEntry) async
}
