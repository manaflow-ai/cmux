import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

/// One non-foreground Mac's persistent read-only connection plus its event consumer.
@MainActor
final class SecondaryMacSubscription {
    let macDeviceID: String
    let client: MobileCoreRPCClient
    /// The route and ticket this client was dialed on, kept for promotion.
    let route: CmxAttachRoute
    let ticket: CmxAttachTicket
    /// Raw host capabilities reported by this secondary Mac.
    let supportedHostCapabilities: Set<String>
    /// Workspace action capabilities reported by this secondary Mac.
    let actionCapabilities: MobileWorkspaceActionCapabilities
    /// Per-connection stream id for the `mobile.events.subscribe` handshake.
    let streamID: String
    var task: Task<Void, Never>?
    /// Coalesces hot `workspace.updated` bursts to one leading and one trailing fetch.
    var refreshTask: Task<Void, Never>?
    var refreshPending = false
    /// Set once the live client has been handed to another owner — currently only
    /// `promoteSecondaryToForeground`, which reuses this connection as the
    /// foreground client. `deinit` must not disconnect a client it no longer owns.
    private var clientHandedOff = false

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
        Task { await client.disconnect() }
    }

    /// Stop the read-only consumer loops while keeping the client connected.
    /// The caller takes ownership of `client` (e.g. foreground promotion), so
    /// `deinit` must no longer disconnect it.
    func detachKeepingClient() {
        task?.cancel()
        task = nil
        refreshTask?.cancel()
        refreshTask = nil
        clientHandedOff = true
    }

    // A subscription dropped without an explicit `cancel()` — e.g. when the
    // owning store is discarded (previews/tests/rebuilds) and its
    // `secondaryMacSubscriptions` dictionary is released — must still stop its
    // consumer loops and disconnect its client; releasing the `Task`/client
    // references alone does neither. Isolated `deinit` is unavailable on the
    // build toolchain, but everything touched here is `Sendable`, and
    // `disconnect()` → `session.tearDown` is idempotent, so running after a
    // prior `cancel()` is a no-op.
    //
    // The one client we must NOT disconnect is a handed-off one: after
    // `detachKeepingClient()` the connection was reused elsewhere (foreground
    // promotion), so disconnecting it here would tear down a live client that
    // another owner now depends on.
    deinit {
        task?.cancel()
        refreshTask?.cancel()
        guard !clientHandedOff else { return }
        let client = self.client
        Task { await client.disconnect() }
    }
}
