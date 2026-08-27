import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// A presence route push proves the Mac's endpoint re-registered, so the shell
/// must invalidate that Mac's reusable transport discovery snapshot before any
/// `.presencePush` recovery dial (docs/transport-plane.md, D5). Without this,
/// the next dial can rebuild its plan from a pre-relaunch snapshot and burn a
/// full timeout against a corpse route.
@MainActor
@Suite struct PresenceDiscoveryInvalidationTests {
    @Test func pushedRoutesInvalidateThatMacsDiscoverySnapshotOnce() async throws {
        let discovery = RecordingIrohDiscovery()
        let shell = MobileShellComposite(
            isSignedIn: true,
            personalIrohDiscovery: discovery,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        let scope = MobileShellScopeSnapshot(
            userID: "user-1",
            teamID: "team-a",
            generation: 0
        )
        let route = try CmxAttachRoute(
            id: "pushed",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.1", port: 51_001)
        )
        // Two instances (tags) on the same physical Mac in one delivery.
        let task = shell.syncPushedRoutes(
            from: [
                PresenceInstance(
                    deviceId: "shared-mac",
                    tag: "feature-a",
                    platform: "mac",
                    online: true,
                    lastSeenAt: 1_000,
                    routes: [route]
                ),
                PresenceInstance(
                    deviceId: "shared-mac",
                    tag: "feature-b",
                    platform: "mac",
                    online: true,
                    lastSeenAt: 1_000,
                    routes: [route]
                ),
            ],
            scope: scope
        )
        await task?.value

        #expect(discovery.invalidatedDeviceIDs == ["shared-mac"])
    }

    @Test func presenceWithoutRoutesDoesNotInvalidateDiscovery() async {
        let discovery = RecordingIrohDiscovery()
        let shell = MobileShellComposite(
            isSignedIn: true,
            personalIrohDiscovery: discovery,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        let scope = MobileShellScopeSnapshot(
            userID: "user-1",
            teamID: "team-a",
            generation: 0
        )
        // Presence-only update: no route payload, so no new endpoint evidence.
        let task = shell.syncPushedRoutes(
            from: [PresenceInstance(
                deviceId: "shared-mac",
                tag: "feature-a",
                platform: "mac",
                online: true,
                lastSeenAt: 1_000
            )],
            scope: scope
        )
        await task?.value

        #expect(discovery.invalidatedDeviceIDs.isEmpty)
    }
}

/// The RPC pairing deadline cancels a wedged in-flight iroh dial, so the
/// transport pool observes only a cancellation and cannot classify the route
/// failure. The shell owner that classified the timeout must therefore report
/// the staleness itself, so the NEXT reconnect attempt rebuilds its dial plan
/// from a fresh broker snapshot instead of burning backoff on a corpse route.
@MainActor
@Suite struct RouteFailureDiscoveryInvalidationTests {
    @Test func timedOutIrohRouteDialInvalidatesDiscoveryForNextAttempt() async throws {
        let discovery = RecordingIrohDiscovery()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let irohRoute = try CmxAttachRoute(
            id: "iroh-personal",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(
                    endpointID: String(repeating: "a", count: 64)
                ),
                pathHints: []
            ),
            priority: -10_000
        )
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [irohRoute],
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: Date()
        )
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        // An iroh dial that neither completes nor fails: the pairing request
        // deadline is the only thing that can settle this attempt.
        factory.setHangingKinds([.iroh])
        let store = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { Date() },
                supportedRouteKinds: [.iroh],
                pairingRequestTimeoutNanoseconds: 50_000_000,
                pairingAttemptTimeoutNanoseconds: 200_000_000
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            personalIrohDiscovery: discovery,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "route-failure-invalidation-\(UUID().uuidString)"
            )!,
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()

        #expect(!(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")))

        #expect(discovery.invalidatedDeviceIDs.contains("test-mac"))
        await factory.releaseHangingTransports()
    }
}

@MainActor
private final class RecordingIrohDiscovery: MobileIrohMacDiscovering {
    private(set) var invalidatedDeviceIDs: [String] = []

    func discoverLiveMacs() async -> [MobileDiscoveredIrohMac] { [] }

    func invalidateDiscovery(forMacDeviceID deviceID: String) async {
        invalidatedDeviceIDs.append(deviceID)
    }
}
