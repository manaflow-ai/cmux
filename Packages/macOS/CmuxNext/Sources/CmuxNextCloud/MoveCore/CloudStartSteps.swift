public import Foundation
public import os

/// A Cloud start's step times, one app log line each (`cloud start step: NAME MS ms`), so the chat probe's
/// `select_marks_ms` (cmuxterm-hq `cloud_chat_app_probe.py`) splits the span from the machine's create to the chat's
/// start: the link, the harness login's owner check, guest and login reads, its transfer's round trips, and the
/// chat's tab and start. Each step runs from the one before it (or this clock's start) to its own end, so the steps
/// add up to the span. Names only, never an id, a path or a token.
@MainActor public final class CloudStartSteps {
    /// What every line starts with: the probe matches it.
    public nonisolated static let prefix = "cloud start step: "
    let log: (String) -> Void
    let now: () -> ContinuousClock.Instant
    private var last: ContinuousClock.Instant

    public init(log: @escaping (String) -> Void, now: @escaping () -> ContinuousClock.Instant = { .now }) {
        (self.log, self.now) = (log, now)
        last = now()
    }

    /// Lines into the app's Cloud log (`app.cloud`), where the probe reads the start's other marks.
    public convenience init(logger: Logger) { self.init(log: { line in logger.info("\(line, privacy: .public)") }) }

    /// Logs `name`'s time since the step before it ended.
    public func done(_ name: String) {
        let end = now()
        log(Self.line(name, last.duration(to: end)))
        last = end
    }

    /// `cloud start step: NAME MS ms`, whole milliseconds, never negative.
    public nonisolated static func line(_ name: String, _ elapsed: Duration) -> String {
        let (seconds, attoseconds) = elapsed.components
        return "\(prefix)\(name) \(max(0, seconds * 1000 + attoseconds / 1_000_000_000_000_000)) ms"
    }
}
