import Foundation
import Sentry

/// Keeps recurring operational transport noise out of the macOS Sentry quota.
///
/// Transport breadcrumbs and structured logs remain available for a later
/// crash or sampled incident. Only the high-volume event surface is filtered:
/// crashes, hangs, and unclassified application errors continue through the
/// normal ``beforeSend`` pipeline.
struct SentryEventNoiseFilter: Sendable {
    /// Operational messages that already have breadcrumb coverage.
    private static let droppedMessagePrefixes = [
        "socket.listener.",
    ]

    /// Fraction of non-outage transport failures retained by the SDK-level
    /// backstop. The incident policy performs the primary sampling; this
    /// second gate protects quota when a process restarts and loses its local
    /// policy state.
    private static let transportFailureSampleRate = 0.05

    /// Outage incidents are already episode-coalesced, so retain a larger
    /// sample to preserve fleet-wide visibility of sustained regressions.
    private static let transportOutageSampleRate = 0.25

    /// Applies the event-level filter after scrubbing.
    ///
    /// - Parameter event: The scrubbed event supplied by Sentry's ``beforeSend``
    ///   callback.
    /// - Returns: The event to send, or `nil` for operational noise.
    func filter(_ event: Event) -> Event? {
        if Self.shouldDrop(message: event.message?.formatted) {
            return nil
        }
        guard event.logger == "cmux.transport" else { return event }

        let failure = event.tags?["transport.failure"]
        if failure == "offline" {
            return nil
        }
        if let transportContext = event.context?["cmux.transport"],
           let reachable = transportContext["reachable"] as? Bool,
           !reachable {
            return nil
        }
        let incident = event.tags?["transport.incident"] ?? "failure"
        let sampleRate = incident == "outage"
            ? Self.transportOutageSampleRate
            : Self.transportFailureSampleRate
        let bucket = String(describing: event.eventId)
        return Self.shouldKeepTransportEvent(
            incident: incident,
            failure: failure,
            bucket: bucket,
            sampleRate: sampleRate
        ) ? event : nil
    }

    /// Pure message filter used by tests and by non-Event call sites.
    static func shouldDrop(message: String?) -> Bool {
        guard let message else { return false }
        return droppedMessagePrefixes.contains { message.hasPrefix($0) }
    }

    /// Deterministic transport-event sampler.
    ///
    /// Explicit offline failures are always dropped. Other decisions hash the
    /// event bucket so tests and process restarts do not depend on global RNG
    /// state. Rates outside `0...1` normalize to the nearest bound.
    static func shouldKeepTransportEvent(
        incident: String,
        failure: String?,
        bucket: String,
        sampleRate: Double
    ) -> Bool {
        guard failure != "offline" else { return false }
        let rate = min(1, max(0, sampleRate))
        guard rate > 0 else { return false }
        guard rate < 1 else { return true }

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in (incident + "|" + (failure ?? "") + "|" + bucket).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Double(hash) / Double(UInt64.max) < rate
    }
}
