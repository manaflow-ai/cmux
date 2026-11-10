public import CmuxConnectivityTelemetry
import CmuxNextCompat
import Foundation
import Sentry

extension CrashReporter {
    /// Sends kept connectivity records (``ConnectivityTelemetry``) to Sentry while it runs (the
    /// person's anonymous-telemetry choice; nothing while it is off).
    ///
    /// Every record becomes a breadcrumb (category `connectivity.<area>`), so a later crash,
    /// hang or failure carries the connection timeline. A failure the gate admits
    /// (``ConnectivityRemoteGate``: every one for the team, one per key an hour for everyone)
    /// is also its own warning event, grouped by its key. The team's records carry their free
    /// text; everyone's carry fixed words and numbers only. Sentry's scrubber still runs over
    /// both (tokens and home paths never leave the Mac).
    public func connectivitySink() -> ConnectivityTelemetry.Sink {
        let forwarder = ConnectivitySentryForwarder(reporter: self)
        return { record in forwarder.forward(record) }
    }

    static func connectivityBreadcrumb(_ record: ConnectivityRecord) -> Breadcrumb {
        let crumb = Breadcrumb(level: record.outcome == .failure ? .warning : .info, category: "connectivity.\(record.area.rawValue)")
        crumb.type = record.outcome == .failure ? "error" : "default"
        crumb.message = record.summary
        crumb.data = connectivityData(record)
        return crumb
    }

    static func connectivityEvent(_ record: ConnectivityRecord) -> Event {
        let event = Event(level: .warning)
        event.message = SentryMessage(formatted: "connectivity \(record.key) failed")
        event.logger = "cmux.connectivity"
        event.fingerprint = ["cmux-connectivity", record.key]
        event.tags = [
            "connectivity.area": record.area.rawValue,
            "connectivity.event": record.name,
            "connectivity.tier": record.audience.rawValue,
        ]
        event.extra = connectivityData(record)
        return event
    }

    static func connectivityData(_ record: ConnectivityRecord) -> [String: Any] {
        var data: [String: Any] = ["tier": record.audience.rawValue, "outcome": record.outcome.rawValue]
        for (key, value) in record.fields {
            switch value {
            case .code(let text), .text(let text): data[key] = text
            case .number(let number): data[key] = number
            case .flag(let flag): data[key] = flag
            }
        }
        if let detail = record.detail { data["detail"] = detail }
        if record.sampleRate > 1 { data["sample_rate"] = record.sampleRate }
        if record.droppedBefore > 0 { data["dropped_before"] = record.droppedBefore }
        return data
    }
}

/// ``CrashReporter/connectivitySink()``'s state: the remote gate.
final class ConnectivitySentryForwarder: Sendable {
    let reporter: CrashReporter
    // Lock carve-out: forward runs synchronously on the recorder's drain task; the region only
    // advances the pure gate.
    private let gate = Mutex(ConnectivityRemoteGate())

    init(reporter: CrashReporter) {
        self.reporter = reporter
    }

    func forward(_ record: ConnectivityRecord) {
        guard reporter.isStarted else { return }
        SentrySDK.addBreadcrumb(CrashReporter.connectivityBreadcrumb(record))
        guard gate.withLock({ $0.sendsEvent(for: record) }) else { return }
        SentrySDK.capture(event: CrashReporter.connectivityEvent(record))
    }
}
