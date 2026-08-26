import CMUXMobileCore
public import Sentry

/// Filters high-volume operational transport events at the Sentry boundary.
///
/// Incident admission and deterministic sampling remain owned by
/// ``CMUXMobileCore/TransportIncidentPolicy``. This filter is only the final
/// event-shape backstop for events that bypass that policy, such as the
/// macOS control-socket listener. Breadcrumbs, structured logs, crashes, and
/// hangs are unaffected.
public struct TransportSentryEventNoiseFilter: Sendable {
    /// Creates the default operational-noise filter.
    public init() {}

    /// Returns the event when it is actionable, or `nil` for routine noise.
    ///
    /// - Parameter event: The scrubbed event supplied by Sentry's
    ///   ``beforeSend`` callback.
    /// - Returns: The event to send, or `nil` when it is operational noise.
    public func filter(_ event: Event) -> Event? {
        if shouldDrop(message: event.message?.formatted) {
            return nil
        }
        guard event.logger == "cmux.transport" else { return event }

        if event.tags?["transport.failure"] == "offline" {
            return nil
        }
        if let transportContext = event.context?["cmux.transport"],
           let reachable = transportContext["reachable"] as? Bool,
           !reachable,
           let failureName = event.tags?["transport.failure"],
           let failure = DiagnosticFailureKind.allCases.first(where: {
               String(describing: $0) == failureName
           }),
           TransportIncidentPolicy.environmentalFailureKinds.contains(failure) {
            return nil
        }
        return event
    }

    /// Returns whether a top-level message is a recurring listener signal.
    ///
    /// - Parameter message: The event message, when present.
    /// - Returns: `true` for socket-listener operational messages.
    public func shouldDrop(message: String?) -> Bool {
        guard let message else { return false }
        // Listener failures are admitted by SocketListenerFailurePolicy, which
        // applies the longer per-key cooldown before capture. Keep those
        // actionable messages available; only surrounding health/retry
        // breadcrumbs are filtered here.
        guard message != "socket.listener.start.failed",
              message != "socket.listener.path.missing" else { return false }
        return Self.droppedMessagePrefixes.contains { message.hasPrefix($0) }
    }

    private static let droppedMessagePrefixes = [
        "socket.listener.",
    ]
}
