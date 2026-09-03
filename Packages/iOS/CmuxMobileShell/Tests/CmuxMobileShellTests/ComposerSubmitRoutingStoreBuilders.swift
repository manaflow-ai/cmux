import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

// Connected-store builders for the composer send-routing tests, split from
// ComposerSubmitRoutingTestSupport.swift (Swift file length threshold).

/// Build a store with a workspace of two terminals (term-a selected) and a real
/// `MobileCoreRPCClient` wired DIRECTLY onto the store, backed by the recording
/// transport. This deliberately bypasses the pairing/connect handshake (which
/// the scripted-host harness cannot complete in this environment): the composer
/// send path only needs a live `remoteClient` to reach the wire, and the
/// session connects its transport lazily on the first request. The result is a
/// deterministic end-to-end exercise of submitComposer's routing over the real
/// terminal.paste / terminal.paste_image RPC frames.
@MainActor
func makeRoutingConnectedStore(
    router: RoutingHostRouter,
    pendingDismissQueue: PendingNotificationDismissQueue = PendingNotificationDismissQueue(
        defaults: UserDefaults(suiteName: "routing-dismiss-\(UUID().uuidString)")!
    ),
    macScopedWorkspaceMutations: Bool = false,
    hostCapabilities: Set<String> = ["workspace.task_create.v1"],
    pairedMacStore: (any MobilePairedMacStoring)? = nil,
    routeKind: CmxAttachTransportKind = .debugLoopback,
    terminalLaneProvider: MobileTerminalLaneProvider? = nil,
    draftStore: (any TerminalDraftStoring)? = nil,
    rpcRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000,
    taskModelCatalogClient: MobileTaskModelCatalogClient = .live()
) async throws -> MobileShellComposite {
    let runtime = RoutingTestRuntime(
        transportFactory: RoutingTransportFactory(router: router),
        terminalLaneProvider: terminalLaneProvider,
        rpcRequestTimeoutNanoseconds: rpcRequestTimeoutNanoseconds,
        supportedRouteKinds: [routeKind]
    )
    let terminals = [
        MobileTerminalPreview(id: .init(rawValue: RoutingHostRouter.terminalA), name: "A"),
        MobileTerminalPreview(id: .init(rawValue: RoutingHostRouter.terminalB), name: "B"),
    ]
    let store = MobileShellComposite(
        runtime: runtime,
        isSignedIn: true,
        connectionState: .connected,
        workspaces: [
            MobileWorkspacePreview(
                id: .init(rawValue: RoutingHostRouter.workspaceID),
                name: "Routing Workspace",
                terminals: terminals
            ),
        ],
        pairedMacStore: pairedMacStore,
        identityProvider: StaticIdentityProvider(userID: "routing-user"),
        pendingDismissQueue: pendingDismissQueue,
        draftStore: draftStore,
        taskModelCatalogClient: taskModelCatalogClient
    )
    // 127.0.0.1 is a Stack-auth-trusted route, so authorized requests carry the
    // Stack token and do not throw insecureManualRoute before reaching the
    // transport. Enable the fallback to match the trusted-route production path.
    let route: CmxAttachRoute
    if routeKind == .iroh {
        route = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(
                    endpointID: String(repeating: "a", count: 64)
                ),
                pathHints: []
            )
        )
    } else if routeKind == .websocket {
        // Mirrors the relay method's synthesized route: a wss URL whose
        // per-connect authority is the minted ticket, dialed here through the
        // recording transport like every other kind.
        route = try CmxAttachRoute(
            id: "relay",
            kind: .websocket,
            endpoint: .url("wss://relay.test.invalid/v1/connect")
        )
    } else {
        route = try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56585)
        )
    }
    let ticket = try CmxAttachTicket(
        workspaceID: macScopedWorkspaceMutations ? "" : RoutingHostRouter.workspaceID,
        terminalID: macScopedWorkspaceMutations ? nil : RoutingHostRouter.terminalA,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(3600),
        authToken: macScopedWorkspaceMutations ? "ticket-secret" : nil
    )
    store.remoteClient = MobileCoreRPCClient(
        runtime: runtime,
        route: route,
        ticket: ticket,
        allowsStackAuthFallback: true
    )
    store.foregroundMacDeviceID = "test-mac"
    store.supportedHostCapabilities = hostCapabilities
    store.activeRoute = route
    store.activeTicket = ticket
    return store
}

/// Install a fresh `remoteClient` on an already-built store, backed by `router`.
/// Models the new transport a reconnect / account switch / Mac switch installs:
/// the mid-submit identity guard must abort BEFORE any further image or the text
/// reaches this second router, so a test can assert that router recorded nothing.
@MainActor
func installFreshRemoteClient(on store: MobileShellComposite, router: RoutingHostRouter) throws {
    let runtime = RoutingTestRuntime(
        transportFactory: RoutingTransportFactory(router: router)
    )
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56586)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: RoutingHostRouter.workspaceID,
        terminalID: RoutingHostRouter.terminalA,
        macDeviceID: "test-mac-2",
        macDisplayName: "Test Mac 2",
        routes: [route],
        expiresAt: Date().addingTimeInterval(3600)
    )
    store.remoteClient = MobileCoreRPCClient(
        runtime: runtime,
        route: route,
        ticket: ticket,
        allowsStackAuthFallback: true
    )
    store.foregroundMacDeviceID = "test-mac-2"
}

/// Install a live read-only secondary client on `store`, backed by `router`.
@MainActor
func installSecondaryClient(
    on store: MobileShellComposite,
    macDeviceID: String,
    instanceTag: String? = nil,
    router: RoutingHostRouter,
    supportedHostCapabilities: Set<String> = []
) throws {
    let runtime = RoutingTestRuntime(
        transportFactory: RoutingTransportFactory(router: router)
    )
    let route = try CmxAttachRoute(
        id: "debug_loopback_\(macDeviceID)",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56587)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: RoutingHostRouter.workspaceID,
        terminalID: RoutingHostRouter.terminalA,
        macDeviceID: macDeviceID,
        macDisplayName: macDeviceID,
        routes: [route],
        expiresAt: Date().addingTimeInterval(3600)
    )
    let client = MobileCoreRPCClient(
        runtime: runtime,
        route: route,
        ticket: ticket,
        allowsStackAuthFallback: true
    )
    let ownerKey = MacPairingKey(macDeviceID: macDeviceID, instanceTag: instanceTag)
    store.secondaryMacSubscriptions[ownerKey] = SecondaryMacSubscription(
        macDeviceID: macDeviceID,
        client: client,
        route: route,
        ticket: ticket,
        storedInstanceTag: instanceTag,
        supportedHostCapabilities: supportedHostCapabilities,
        actionCapabilities: .none
    )
}
