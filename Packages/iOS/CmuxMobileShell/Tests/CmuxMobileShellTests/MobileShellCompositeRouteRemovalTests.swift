import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellCompositeRouteRemovalTests {
    @Test func deletingActiveTailscaleRouteDisconnectsForegroundSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let activeRoute = try CmxAttachRoute(
            id: "tailscale-active",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.17", port: 56_584)
        )
        let fallbackRoute = try CmxAttachRoute(
            id: "tailscale-fallback",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.18", port: 56_584)
        )
        let now = Date()
        try await pairedStore.upsert(
            macDeviceID: "mac-route-removal",
            displayName: "Route Removal Mac",
            routes: [activeRoute, fallbackRoute],
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: now
        )

        let router = LivenessHostRouter()
        let closeGate = LivenessTransportCloseGate()
        let transportBox = TransportBox()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: transportBox,
                closeGate: closeGate
            ),
            now: { now }
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )
        await shell.loadPairedMacs()

        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-a",
            terminalID: "terminal-a",
            macDeviceID: "mac-route-removal",
            macDisplayName: "Route Removal Mac",
            routes: [activeRoute],
            expiresAt: now.addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: activeRoute,
            ticket: ticket
        )
        _ = try await client.sendRequest(
            MobileCoreRPCClient.requestData(
                method: "mobile.host.status",
                params: [:]
            )
        )

        shell.remoteClient = client
        shell.activeTicket = ticket
        shell.activeRoute = activeRoute
        shell.foregroundMacDeviceID = "mac-route-removal"
        shell.connections[MacPairingKey(macDeviceID: "mac-route-removal", instanceTag: nil)] = MacConnection(
            macDeviceID: "mac-route-removal",
            ticket: ticket,
            route: activeRoute,
            client: client,
            generation: shell.connectionGeneration,
            displayName: "Route Removal Mac",
            instanceTag: nil,
            supportedHostCapabilities: [],
            actionCapabilities: .none
        )

        #expect(await shell.removeRoute(
            activeRoute,
            macDeviceID: "mac-route-removal",
            instanceTag: nil
        ))
        #expect(shell.remoteClient == nil)
        #expect(shell.activeRoute == nil)
        #expect(shell.connectionState == .disconnected)
        #expect(shell.connections[MacPairingKey(macDeviceID: "mac-route-removal", instanceTag: nil)] == nil)
        #expect(await closeGate.waitUntilCloseStarted())

        await closeGate.release()
    }
}
