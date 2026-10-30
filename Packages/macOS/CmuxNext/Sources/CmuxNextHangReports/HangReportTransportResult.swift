/// What the server said about one report.
public enum HangReportTransportResult: Sendable, Equatable {
    /// Stored, or already stored (`204`): drop it from the outbox.
    case accepted
    /// Refused for good (`400`, `413`): drop it, never retry.
    case refused(status: Int)
    /// Rate limited, a server error or no network: keep it for the next trigger.
    case retryLater
}
