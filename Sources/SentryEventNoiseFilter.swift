/// Centralized `beforeSend` backstop that drops high-frequency operational
/// noise from Sentry.
///
/// The `cmuxterm-macos` project blew past its monthly event quota (tens of
/// millions of events) and Sentry began rate-limiting 100% of ingestion, so
/// real crashes stopped being recorded. The dominant source was the CLI
/// (handled separately by `CLISocketErrorClassification`); this filter is the
/// app-side guarantee that the recurring operational signals which already emit
/// breadcrumbs do not also become events.
///
/// The filter keys only on the event's top-level *message*. Process crashes and
/// app-hang (ANR) reports do not carry these messages (their titles come from
/// exceptions), so they always pass through. Anything unrecognized is kept.
enum SentryEventNoiseFilter {
    /// Messages whose prefix marks them as recurring operational noise. The
    /// socket listener already records every one of these as a breadcrumb.
    static let droppedMessagePrefixes: [String] = [
        "socket.listener."
    ]

    /// Exact messages dropped as high-frequency, low-signal telemetry.
    static let droppedMessages: Set<String> = [
        "Scroll lag detected"
    ]

    /// Pure decision used by ``filter(_:)``: should an event with this
    /// top-level message be dropped? `nil` and unrecognized messages are kept,
    /// so crashes, ANR reports, and genuine errors are never affected.
    static func shouldDrop(message: String?) -> Bool {
        guard let message else { return false }
        if droppedMessages.contains(message) { return true }
        return droppedMessagePrefixes.contains { message.hasPrefix($0) }
    }
}
