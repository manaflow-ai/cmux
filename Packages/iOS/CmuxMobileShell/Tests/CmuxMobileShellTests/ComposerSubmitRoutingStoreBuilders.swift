import CMUXMobileCore
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
    macScopedWorkspaceMutations: Bool = false
) async throws -> MobileShellComposite {
    let runtime = RoutingTestRuntime(
        transportFactory: RoutingTransportFactory(router: router)
    )
    let terminals = [
        MobileTerminalPreview(id: .init(rawValue: RoutingHostRouter.terminalA), name: "A"),
        MobileTerminalPreview(id: .init(rawValue: RoutingHostRouter.terminalB), name: "B"),
    ]
    let store = MobileShellComposite(
        runtime: runtime,
        isSignedIn: true,
        workspaces: [
            MobileWorkspacePreview(
                id: .init(rawValue: RoutingHostRouter.workspaceID),
                name: "Routing Workspace",
                terminals: terminals
            ),
        ],
        pendingDismissQueue: pendingDismissQueue
    )
    // 127.0.0.1 is a Stack-auth-trusted route, so authorized requests carry the
    // Stack token and do not throw insecureManualRoute before reaching the
    // transport. Enable the fallback to match the trusted-route production path.
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56585)
    )
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
    router: RoutingHostRouter
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
    store.secondaryMacSubscriptions[macDeviceID] = SecondaryMacSubscription(
        macDeviceID: macDeviceID,
        client: client,
        route: route,
        ticket: ticket,
        supportedHostCapabilities: [],
        actionCapabilities: .none
    )
}
