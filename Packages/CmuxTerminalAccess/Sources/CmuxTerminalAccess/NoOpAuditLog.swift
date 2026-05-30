/// Discard-everything ``AuditLog``.
///
/// **Tests only** (D4) — never wire this in as the production
/// default. Production wiring uses ``FileAuditLog``; the Settings UI
/// only toggles the file PATH.
public final class NoOpAuditLog: AuditLog {
    /// Creates a no-op sink.
    public init() {}

    /// Discards `entry` and returns immediately.
    public func record(_ entry: AuditEntry) async {}
}
