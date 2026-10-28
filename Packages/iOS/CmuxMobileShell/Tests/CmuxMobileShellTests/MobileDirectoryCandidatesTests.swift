import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileDirectoryCandidatesTests {
    @Test func aDiscoveredMacAppearsOnceWithoutCreatingAPairing() async throws {
        let mac = try candidate("mac-a")
        let discovery = PendingDirectoryDiscovery()
        let shell = makeShell(discovery)
        let refresh = Task { await shell.refreshDirectoryCandidates() }
        await discovery.waitForRequest(1)
        discovery.finish(1, with: [mac, mac])
        await refresh.value

        #expect(shell.discoveredIrohMacs.map(\.deviceID) == ["mac-a"])
        #expect(shell.pairedMacs.isEmpty)
        #expect(shell.connectionState == .disconnected)
    }

    @Test func anOlderDirectoryResponseCannotReplaceTheLatestList() async throws {
        let discovery = PendingDirectoryDiscovery()
        let shell = makeShell(discovery)
        let first = Task { await shell.refreshDirectoryCandidates() }
        await discovery.waitForRequest(1)
        let second = Task { await shell.refreshDirectoryCandidates() }
        await discovery.waitForRequest(2)
        discovery.finish(2, with: [try candidate("new-mac")])
        await second.value
        discovery.finish(1, with: [try candidate("old-mac")])
        await first.value

        #expect(shell.discoveredIrohMacs.map(\.deviceID) == ["new-mac"])
    }

    @Test func aCancelledRefreshCannotPublishItsDirectory() async throws {
        let discovery = PendingDirectoryDiscovery()
        let shell = makeShell(discovery)
        let refresh = Task { await shell.refreshDirectoryCandidates() }
        await discovery.waitForRequest(1)
        refresh.cancel()
        discovery.finish(1, with: [try candidate("mac-a")])
        await refresh.value

        #expect(shell.discoveredIrohMacs.isEmpty)
    }

    @Test func losingTheSignedInIdentityClearsTheDirectory() async throws {
        let discovery = PendingDirectoryDiscovery()
        let identity = StaticIdentityProvider(userID: "user-1")
        let shell = makeShell(discovery, identity: identity)
        let refresh = Task { await shell.refreshDirectoryCandidates() }
        await discovery.waitForRequest(1)
        discovery.finish(1, with: [try candidate("mac-a")])
        await refresh.value
        #expect(shell.discoveredIrohMacs.count == 1)

        identity.currentUserID = nil
        await shell.refreshDirectoryCandidates()
        #expect(shell.discoveredIrohMacs.isEmpty)
    }

    @Test func aResponseAfterIdentityLossCannotPublish() async throws {
        let discovery = PendingDirectoryDiscovery()
        let identity = StaticIdentityProvider(userID: "user-1")
        let shell = makeShell(discovery, identity: identity)
        let refresh = Task { await shell.refreshDirectoryCandidates() }
        await discovery.waitForRequest(1)
        identity.currentUserID = nil
        discovery.finish(1, with: [try candidate("mac-a")])
        await refresh.value

        #expect(shell.discoveredIrohMacs.isEmpty)
    }

    @Test func aPrivatePathCannotChangeATailscalePairingToIroh() throws {
        let shell = makeShell(PendingDirectoryDiscovery())
        let mac = try candidate("mac-a")
        let pairing = MobilePairedMac(
            macDeviceID: mac.deviceID,
            displayName: mac.displayName,
            routes: mac.routes,
            createdAt: mac.lastSeenAt,
            lastSeenAt: mac.lastSeenAt,
            isActive: false,
            stackUserID: "user-1",
            instanceTag: mac.instanceTag,
            connectionMethodRawValue: MobileConnectionMethod.tailscale.rawValue
        )
        let plan = shell.storedMacDialPlan(
            routes: mac.routes,
            pairedMacDeviceID: mac.deviceID,
            expectedInstanceTag: mac.instanceTag,
            legacyTailscaleRoutes: [],
            knownPairing: pairing,
            directOnlyDialCandidates: [CmxIrohDirectDialCandidate(address: "100.64.0.2", port: 52074)]
        )

        #expect(plan.method == .tailscale)
        #expect(plan.methodPinnedCandidates == nil)
        #expect(plan.routes.isEmpty)
    }

    @Test func aLiveDirectoryUpdateReplacesTheTemporaryRows() async throws {
        let discovery = LiveDirectoryDiscovery(candidates: [try candidate("old-mac")])
        let shell = makeShell(discovery)
        await shell.refreshDirectoryCandidates()
        #expect(shell.discoveredIrohMacs.map(\.deviceID) == ["old-mac"])

        discovery.setCandidates([try candidate("new-mac")])
        shell.evaluatePresenceSubscription()
        discovery.emitUpdate()
        for _ in 0 ..< 100 {
            await Task.yield()
            if shell.discoveredIrohMacs.map(\.deviceID) == ["new-mac"] { break }
        }

        #expect(shell.discoveredIrohMacs.map(\.deviceID) == ["new-mac"])
    }

    private func makeShell(
        _ discovery: any MobileIrohMacDiscovering,
        identity: StaticIdentityProvider? = nil
    ) -> MobileShellComposite {
        let defaults = UserDefaults(suiteName: "directory-candidates-\(UUID().uuidString)")!
        return MobileShellComposite(
            isSignedIn: true,
            personalIrohDiscovery: discovery,
            clientIDRepository: MobileClientIDRepository(defaults: defaults),
            identityProvider: identity ?? StaticIdentityProvider(userID: "user-1"),
            pairingHintDefaults: defaults,
            multiMacAggregationDefaults: defaults
        )
    }

    private func candidate(_ deviceID: String) throws -> MobileDiscoveredIrohMac {
        MobileDiscoveredIrohMac(
            deviceID: deviceID,
            displayName: deviceID,
            instanceTag: "stable",
            routes: [try CmxAttachRoute(
                id: "iroh-\(deviceID)",
                kind: .iroh,
                endpoint: .peer(
                    identity: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)),
                    pathHints: []
                )
            )],
            lastSeenAt: Date(timeIntervalSince1970: 30)
        )
    }
}
