import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

/// One-shot acknowledgement used by focus promotion to wait until the
/// foreground event listener exists locally and its server registration has
/// been acknowledged.
actor MobileTerminalEventSubscriptionReadiness {
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func wait() async -> Bool {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func resolve(_ value: Bool) {
        guard result == nil else { return }
        result = value
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume(returning: value)
        }
    }
}

/// One non-focused Mac's persistent control connection plus its event consumer.
@MainActor
final class SecondaryMacSubscription {
    /// Control-plane topics intentionally exclude terminal render and byte traffic.
    static let eventTopics: Set<String> = [
        "workspace.updated",
        "notification.feed.changed",
    ]

    let macDeviceID: String
    let client: MobileCoreRPCClient
    /// The route and ticket this client was dialed on, kept for promotion.
    let route: CmxAttachRoute
    let ticket: CmxAttachTicket
    /// Paired-row authority captured when this subscription was established.
    let storedInstanceTag: String?
    /// Instance identity proven by authenticated host status on this client.
    let authenticatedInstanceTag: String?
    /// Raw host capabilities reported by this secondary Mac.
    let supportedHostCapabilities: Set<String>
    /// Workspace action capabilities reported by this secondary Mac.
    let actionCapabilities: MobileWorkspaceActionCapabilities
    /// Human-readable Mac name for settings and diagnostics.
    let displayName: String?
    /// Per-connection stream id for the `mobile.events.subscribe` handshake.
    let streamID: String
    var task: Task<Void, Never>?
    /// Coalesces hot `workspace.updated` bursts to one leading and one trailing fetch.
    var refreshTask: Task<Void, Never>?
    var refreshPending = false
    /// Set before promotion waits on any RPC. Keepalive reassertions skip this
    /// subscription until it either becomes focused or promotion is abandoned.
    var isTransitioningToFocus = false
    /// Keepalive ticks skip a newly inserted subscription until its consumer's
    /// first server-side activation has completed.
    var hasActivatedControlStream = false
    /// Records an event consumer ending while promotion owns the subscription.
    /// If promotion is then abandoned before focus commits, the dead control
    /// connection is torn down instead of being returned to the pool.
    var eventStreamEndedDuringFocusTransition = false

    init(
        macDeviceID: String,
        client: MobileCoreRPCClient,
        route: CmxAttachRoute,
        ticket: CmxAttachTicket,
        storedInstanceTag: String? = nil,
        authenticatedInstanceTag: String? = nil,
        supportedHostCapabilities: Set<String>,
        actionCapabilities: MobileWorkspaceActionCapabilities,
        displayName: String? = nil
    ) {
        self.macDeviceID = macDeviceID
        self.client = client
        self.route = route
        self.ticket = ticket
        self.storedInstanceTag = storedInstanceTag
        self.authenticatedInstanceTag = authenticatedInstanceTag
        self.supportedHostCapabilities = supportedHostCapabilities
        self.actionCapabilities = actionCapabilities
        self.displayName = displayName
        self.streamID = "ios-secondary-events-\(macDeviceID)-\(UUID().uuidString)"
    }

    func cancel() {
        task?.cancel()
        task = nil
        refreshTask?.cancel()
        refreshTask = nil
        let client = self.client
        Task { await client.disconnect() }
    }

    /// Stop the read-only consumer loops while keeping the client connected.
    func detachKeepingClient() {
        task?.cancel()
        task = nil
        refreshTask?.cancel()
        refreshTask = nil
    }
}
