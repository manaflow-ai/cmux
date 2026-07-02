public import Foundation

/// Actor-backed ring buffer of recent human-readable mobile diagnostics events.
public actor MobileDiagnosticsEventLog {
    private var events: [MobileDiagnosticsEvent] = []
    private let capacity: Int
    private let now: @Sendable () -> Date
    private let scrubber: MobileDiagnosticsSecretScrubber

    /// Create an event log.
    ///
    /// - Parameters:
    ///   - capacity: Maximum number of retained events.
    ///   - now: Clock used to timestamp events. Injected for deterministic tests.
    ///   - scrubber: Secret scrubber applied before event fields are retained.
    public init(
        capacity: Int = 200,
        now: @escaping @Sendable () -> Date = { Date() },
        scrubber: MobileDiagnosticsSecretScrubber = MobileDiagnosticsSecretScrubber()
    ) {
        self.capacity = max(1, capacity)
        self.now = now
        self.scrubber = scrubber
    }

    /// Record an event with optional fields.
    ///
    /// - Parameters:
    ///   - name: Stable event name, such as `conn.state`.
    ///   - fields: Small key/value payload. Values are scrubbed before storage.
    public func record(_ name: String, fields: [String: String] = [:]) {
        let scrubbedFields = fields.mapValues { scrubber.scrub($0) }
        events.append(MobileDiagnosticsEvent(date: now(), name: name, fields: scrubbedFields))
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    /// Return retained events in chronological order.
    ///
    /// - Returns: The retained events, oldest first.
    public func snapshot() -> [MobileDiagnosticsEvent] {
        events
    }

    /// Remove every retained event.
    public func clear() {
        events.removeAll(keepingCapacity: true)
    }
}
