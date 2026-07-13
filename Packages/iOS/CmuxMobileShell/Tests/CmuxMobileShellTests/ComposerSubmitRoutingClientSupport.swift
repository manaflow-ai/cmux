import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
@testable import CmuxMobileShell

/// Installs a replacement foreground client for mid-submit identity tests.
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
    store.replaceRemoteClient(with: MobileCoreRPCClient(
        runtime: runtime,
        route: route,
        ticket: ticket,
        allowsStackAuthFallback: true
    ))
    store.foregroundMacDeviceID = "test-mac-2"
}

/// Builds a store with a real client backed by the deterministic routing host.
@MainActor
func makeRoutingConnectedStore(
    router: RoutingHostRouter,
    pendingDismissQueue: PendingNotificationDismissQueue = PendingNotificationDismissQueue(
        defaults: UserDefaults(suiteName: "routing-dismiss-\(UUID().uuidString)")!
    ),
    macScopedWorkspaceMutations: Bool = false,
    clientIDRepository: MobileClientIDRepository = MobileClientIDRepository(defaults: .standard)
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
        clientIDRepository: clientIDRepository,
        pendingDismissQueue: pendingDismissQueue
    )
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

/// Installs a live read-only secondary client on `store`.
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
