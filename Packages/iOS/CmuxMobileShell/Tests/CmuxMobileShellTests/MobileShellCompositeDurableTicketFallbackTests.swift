import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellCompositeDurableTicketFallbackTests {
    @Test func reconnectRetriesFreshManualTicketWhenPersistedAttachTokenIsUnauthorized() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort)
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let expiresAt = now.addingTimeInterval(3600)
        try await pairedStore.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [route],
            attachToken: "stale-token",
            attachTokenExpiresAt: expiresAt,
            attachTokenWorkspaceID: "",
            attachTokenTerminalID: nil,
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: now
        )

        let router = DurableTicketFallbackRouter(
            route: route,
            expiresAt: expiresAt
        )
        let runtime = DurableTicketFallbackRuntime(
            transportFactory: DurableTicketFallbackTransportFactory(router: router),
            now: { now }
        )
        let defaultsSuiteName = "MobileShellCompositeDurableTicketFallbackTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: defaults,
            multiMacAggregationDefaults: defaults
        )

        let reconnected = await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")

        #expect(reconnected)
        #expect(store.connectionState == .connected)
        let requests = await router.requests()
        #expect(requests.map(\.method) == [
            "workspace.list",
            "mobile.attach_ticket.create",
            "workspace.list",
            "workspace.list",
        ])
        guard requests.count >= 4 else { return }
        #expect(requests[0].attachToken == "stale-token")
        #expect(requests[0].stackAccessToken == nil)
        #expect(requests[1].attachToken == nil)
        #expect(requests[1].stackAccessToken == "fresh-stack-token")
        #expect(requests[2].attachToken == nil)
        #expect(requests[2].stackAccessToken == "fresh-stack-token")
        #expect(requests[2].workspaceID == nil)
        #expect(requests[3].attachToken == "fresh-token")
        #expect(requests[3].stackAccessToken == nil)
        #expect(requests[3].workspaceID == DurableTicketFallbackRouter.workspaceID)
    }

    @Test func durableAttachTicketPreservesPersistedScope() throws {
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort)
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let expiresAt = now.addingTimeInterval(3600)
        let router = DurableTicketFallbackRouter(route: route, expiresAt: expiresAt)
        let store = MobileShellComposite(
            runtime: DurableTicketFallbackRuntime(
                transportFactory: DurableTicketFallbackTransportFactory(router: router),
                now: { now }
            )
        )
        let scopedMac = MobilePairedMac(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [route],
            attachToken: "scoped-token",
            attachTokenExpiresAt: expiresAt,
            attachTokenWorkspaceID: "workspace-a",
            attachTokenTerminalID: "terminal-a",
            createdAt: now,
            lastSeenAt: now,
            isActive: true,
            stackUserID: "user-1"
        )
        let scopedTicket = try #require(store.durableAttachTicket(for: scopedMac))
        #expect(scopedTicket.workspaceID == "workspace-a")
        #expect(scopedTicket.terminalID == "terminal-a")

        var unknownScopeMac = scopedMac
        unknownScopeMac.attachTokenWorkspaceID = nil
        #expect(store.durableAttachTicket(for: unknownScopeMac) == nil)
    }
}
