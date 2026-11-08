/// Freshness of a census from one fixed host/security context.
public enum ProcessSnapshotFreshness: Sendable {
    /// Enumeration must start after this request is admitted by the owner.
    case afterRequest
    /// The census must be no older than this bound at delivery, including capture time.
    case maximumAge(Duration)
}
