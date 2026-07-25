import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

/// One non-focused Mac's persistent control connection plus its event consumer.
@MainActor
final class SecondaryMacSubscription {
    /// Control-plane topics intentionally exclude terminal render and byte traffic.
    static let eventTopics: Set<String> = [
        "workspace.updated",
        "mobile.sync.delta",
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
    /// Reasserts the lightweight server subscription often enough to keep relay
    /// and carrier-NAT paths warm without requesting terminal render traffic.
    var keepaliveTask: Task<Void, Never>?
    /// Coalesces hot `workspace.updated` bursts to one leading and one trailing fetch.
    var refreshTask: Task<Void, Never>?
    var refreshPending = false

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
        keepaliveTask?.cancel()
        keepaliveTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        let client = self.client
        Task { await client.disconnect() }
    }

    /// Stop the read-only consumer loops while keeping the client connected.
    func detachKeepingClient() {
        task?.cancel()
        task = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        refreshTask?.cancel()
        refreshTask = nil
    }
}
