import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

/// One non-foreground Mac's persistent read-only connection plus its event consumer.
@MainActor
final class SecondaryMacSubscription {
    let macDeviceID: String
    /// The route and ticket this client was dialed on, kept for promotion.
    @CancelOnDeinit var client: MobileCoreRPCClient
    let route: CmxAttachRoute
    let ticket: CmxAttachTicket
    /// Raw host capabilities reported by this secondary Mac.
    let supportedHostCapabilities: Set<String>
    /// Workspace action capabilities reported by this secondary Mac.
    let actionCapabilities: MobileWorkspaceActionCapabilities
    /// Per-connection stream id for the `mobile.events.subscribe` handshake.
    let streamID: String
    @CancelOnDeinit var task: Task<Void, Never>?
    /// Coalesces hot `workspace.updated` bursts to one leading and one trailing fetch.
    @CancelOnDeinit var refreshTask: Task<Void, Never>?
    var refreshPending = false

    init(
        macDeviceID: String,
        client: MobileCoreRPCClient,
        route: CmxAttachRoute,
        ticket: CmxAttachTicket,
        supportedHostCapabilities: Set<String>,
        actionCapabilities: MobileWorkspaceActionCapabilities
    ) {
        self.macDeviceID = macDeviceID
        self.client = client
        self.route = route
        self.ticket = ticket
        self.supportedHostCapabilities = supportedHostCapabilities
        self.actionCapabilities = actionCapabilities
        self.streamID = "ios-secondary-events-\(macDeviceID)-\(UUID().uuidString)"
    }

    func cancel() {
        task?.cancel()
        task = nil
        refreshTask?.cancel()
        refreshTask = nil
        let client = self.client
        _client.disarm()
        Task { await client.disconnect() }
    }

    /// Stop the read-only consumer loops while keeping the client connected.
    func detachKeepingClient() {
        task?.cancel()
        task = nil
        refreshTask?.cancel()
        refreshTask = nil
        _client.disarm()
    }
}
