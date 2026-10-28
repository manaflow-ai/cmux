public import Observation

/// Events that are not part of the tree snapshot (bookmarks, local
/// conversations, the app supervisor's `apps-*` events), fanned out in arrival order to the services that own their
/// projections. Each subscriber filters the cases it needs.
@MainActor
@Observable
public final class DaemonSideEvents {
    @ObservationIgnored private var subscribers: [UInt64: (DaemonEvent, DaemonEventEnvelope?) -> Void] = [:]
    @ObservationIgnored private var next: UInt64 = 0
    /// Last stamped connected event applied by this store, cleared on disconnect or unstamped admission.
    public private(set) var controlStamp: DaemonControlStamp?

    public init() {}

    /// Only connection lifecycle application can admit this store's control stamp.
    func noteControl(_ envelope: DaemonEventEnvelope?) { controlStamp = envelope.flatMap(DaemonControlStamp.init) }

    /// Adds a subscriber; returns the token that removes it.
    @discardableResult
    public func subscribe(_ handler: @escaping (DaemonEvent) -> Void) -> UInt64 {
        add { event, _ in handler(event) }
    }

    /// Subscribes to side events with their original control-connection stamp.
    ///
    /// Events without a source ID or envelope do not reach this listener.
    /// Match the captured connection and serial before interpreting demand or
    /// lease metadata; snapshot retention does not establish current authority.
    /// - Parameter handler: Receives the original native event and sequence.
    /// - Returns: The token removed by ``unsubscribe(_:)``.
    @discardableResult
    public func subscribeEnvelopes(_ handler: @escaping (DaemonEventEnvelope) -> Void) -> UInt64 {
        add { _, envelope in
            guard let envelope, envelope.sourceID != nil else { return }
            handler(envelope)
        }
    }

    private func add(_ handler: @escaping (DaemonEvent, DaemonEventEnvelope?) -> Void) -> UInt64 {
        next += 1
        subscribers[next] = handler
        return next
    }

    public func unsubscribe(_ token: UInt64) {
        subscribers[token] = nil
    }

    /// The subscribers now (tests prove a finished stream left none behind).
    var subscriberCount: Int { subscribers.count }

    /// An event of the app supervisor (capability `apps-v1`): `apps-changed`,
    /// `apps-scene`, `apps-provider-request` and the rest. This module does not
    /// model them (`DaemonEvent.unknown`); the apps client reads them.
    public nonisolated static func isAppsEvent(_ name: String) -> Bool { name.hasPrefix("apps-") }

    func deliver(_ event: DaemonEvent, envelope: DaemonEventEnvelope? = nil) {
        for subscriber in subscribers.values { subscriber(event, envelope) }
    }
}
