import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

/// One peer session's persistent control capability plus its event consumer.
/// The same client may concurrently own the focused terminal capability.
@MainActor
final class SecondaryMacSubscription {
    /// Control-plane topics intentionally exclude terminal render and byte traffic.
    static let eventTopics: Set<String> = [
        "workspace.updated",
        "notification.feed.changed",
    ]

    let macDeviceID: String
    /// The typed pool identity: canonical device + STORED tag (the paired
    /// row's authority; adopted/authenticated tags never re-key a live entry).
    var ownerKey: MacPairingKey {
        MacPairingKey(macDeviceID: macDeviceID, instanceTag: storedInstanceTag)
    }
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
    /// Identifies the current per-Mac workspace refresh owner so an older task
    /// cannot clear a replacement after cancellation or role transition.
    var refreshOperationID: UUID?
    /// Coalescing pause between bounded leading/trailing refresh owners. A hot
    /// event stream gets periodic freshness without a tight request train.
    var deferredRefreshTask: Task<Void, Never>?
    var deferredRefreshOperationID: UUID?
    var refreshPending = false
    /// Increments for every workspace event, including events coalesced behind
    /// an in-flight refresh, so independent catch-up fetches cannot overwrite
    /// a newer event-driven result.
    var workspaceRefreshGeneration: UInt64 = 0
    /// Set before promotion waits on any RPC. Keepalive reassertions skip this
    /// subscription until it either becomes focused or promotion is abandoned.
    var isTransitioningToFocus = false
    /// Physical close finished for a non-public drain reservation. Completed
    /// reservations stay claimed until the active Mac switch either consumes
    /// them in its fresh-dial fallback or ends.
    var hasCompletedTransportDrain = false
    var transportDrainOperation: SecondaryMacTransportDrainOperation?
    /// Fresh connect attempts retain the drained target's pool slot until
    /// their replacement focus either publishes or fails.
    var transportDrainReservationHolders: Set<UUID> = []
    var postDrainAction: SecondaryMacPostDrainAction = .none
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
        let identityID = CmxMacAppInstanceIdentity(
            macDeviceID: macDeviceID,
            instanceTag: storedInstanceTag
        ).id
        self.streamID = "ios-secondary-events-\(identityID)-\(UUID().uuidString)"
    }

    func cancel() {
        task?.cancel()
        task = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshOperationID = nil
        deferredRefreshTask?.cancel()
        deferredRefreshTask = nil
        deferredRefreshOperationID = nil
        guard transportDrainOperation == nil else { return }
        let client = self.client
        Task { await client.disconnect() }
    }

    /// Stop the read-only consumer loops while keeping the client connected.
    func detachKeepingClient() {
        task?.cancel()
        task = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshOperationID = nil
        deferredRefreshTask?.cancel()
        deferredRefreshTask = nil
        deferredRefreshOperationID = nil
    }
}
