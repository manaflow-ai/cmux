public import Foundation

/// Pure host-side state machine for deciding when an RPC connection is usable.
///
/// The host adapter records successful protocol observations and supplies the
/// app-owned subscription-liveness check. The tracker owns ordering, one-shot
/// publication, and the protocol requirements shared with mobile clients.
public struct MobileRPCReadinessTracker: Sendable {
    /// One event registration that can make a connection usable.
    public struct EventSubscription: Equatable, Sendable {
        /// Server-owned event stream identifier.
        public let streamID: String
        /// Stable mobile client identifier supplied during subscription.
        public let clientID: String
        /// Negotiated event delivery transport.
        public let transport: String

        /// Creates a protocol-level event registration observation.
        public init(streamID: String, clientID: String, transport: String) {
            self.streamID = streamID
            self.clientID = clientID
            self.transport = transport
        }
    }

    /// Successful RPC response evidence that contributes to readiness.
    public enum Contribution: Equatable, Sendable {
        /// A workspace-list response and the number of available workspaces.
        case workspaceList(count: Int)
        /// A successful subscription carrying the required live-state topics.
        case eventSubscription(EventSubscription)
    }

    /// Complete protocol evidence for a usable mobile session.
    public struct UsableSession: Equatable, Sendable {
        /// Number of workspaces returned by the host.
        public let workspaceCount: Int
        /// Live event registration for workspace and terminal updates.
        public let eventSubscription: EventSubscription
    }

    private var workspaceCount: Int?
    private var eventSubscription: EventSubscription?
    private var didPublish = false

    /// Creates an empty readiness tracker.
    public init() {}

    /// Converts a successful workspace-list response into readiness evidence.
    ///
    /// Both the current and legacy workspace-list method names share the same
    /// contract. A zero count is still recorded so it clears older evidence.
    public static func workspaceListContribution(
        method: String,
        count: Int
    ) -> Contribution? {
        guard method == "workspace.list"
                || method == "mobile.workspace.list" else {
            return nil
        }
        return .workspaceList(count: count)
    }

    /// Converts a successful event-subscribe response into readiness evidence.
    ///
    /// A usable subscription must carry workspace snapshots and deltas plus at
    /// least one terminal-output topic. Blank registration metadata is rejected.
    public static func eventSubscriptionContribution(
        method: String,
        topics: Set<String>,
        streamID: String?,
        clientID: String?,
        transport: String?
    ) -> Contribution? {
        guard method == "mobile.events.subscribe" else { return nil }
        let includesWorkspaceState = topics.contains("workspace.updated")
            && topics.contains("mobile.sync.delta")
        let includesTerminalOutput = topics.contains("terminal.render_grid")
            || topics.contains("terminal.bytes")
        guard includesWorkspaceState,
              includesTerminalOutput,
              let streamID,
              !streamID.isEmpty,
              let clientID,
              !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let transport,
              !transport.isEmpty else {
            return nil
        }
        return .eventSubscription(EventSubscription(
            streamID: streamID,
            clientID: clientID,
            transport: transport
        ))
    }

    /// Records one successful response observation.
    public mutating func record(_ contribution: Contribution) {
        switch contribution {
        case .workspaceList(let count):
            workspaceCount = count > 0 ? count : nil
        case .eventSubscription(let subscription):
            eventSubscription = subscription
        }
    }

    /// Removes readiness evidence for an event stream that was unregistered.
    public mutating func discardEventSubscription(streamID: String) {
        guard eventSubscription?.streamID == streamID else { return }
        eventSubscription = nil
    }

    /// Removes event evidence when the host adapter no longer considers it live.
    public mutating func discardEventSubscription(
        unless isLive: (EventSubscription) -> Bool
    ) {
        guard let eventSubscription, !isLive(eventSubscription) else { return }
        self.eventSubscription = nil
    }

    /// Returns publishable evidence when every protocol condition is satisfied.
    ///
    /// The app adapter supplies the transport-owned liveness check because the
    /// pure package state machine does not own host connection registrations.
    public func usableSession(
        whereEventSubscriptionIsLive isLive: (EventSubscription) -> Bool
    ) -> UsableSession? {
        guard !didPublish,
              let workspaceCount,
              let eventSubscription,
              isLive(eventSubscription) else {
            return nil
        }
        return UsableSession(
            workspaceCount: workspaceCount,
            eventSubscription: eventSubscription
        )
    }

    /// Marks the connection's usable-session event as published.
    public mutating func markPublished() {
        didPublish = true
    }
}
