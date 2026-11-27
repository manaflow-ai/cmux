import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// A Mac that accepts the transport but never answers must not spend the
/// whole reconnect attempt. Each Mac dials under its own deadline, so a live
/// Mac behind a dead one connects once the dead Mac's deadline expires, while
/// the reconnect attempt deadline is still pending.
@MainActor
@Suite
struct IrohMacDiscoveryDeadlineTests {
    @Test
    func deadSavedActiveMacDoesNotStarveLiveSavedMac() async throws {
        let dead = try macDialCandidate(deviceID: "mac-dead", endpointByte: "a")
        let live = try macDialCandidate(deviceID: "mac-live", endpointByte: "b")
        let fixture = try await MacDialFixture.make(macs: [dead, live], discovered: [])
        defer { fixture.cleanup() }
        let deadRouter = try fixture.router(for: dead)
        for number in 1...3 {
            await deadRouter.delayHostStatusRequest(number: number)
        }
        try await fixture.save(dead, active: true)
        try await fixture.save(live, active: false)

        let result = ReconnectResult()
        let reconnect = Task { @MainActor in
            result.value = await fixture.shell.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        // The dead Mac holds its first request under its own deadline.
        let deadDialHasDeadline = try await pollUntil {
            await deadRouter.heldRequestCount() == 1
                && fixture.macDialDeadlines.pendingCount >= 1
        }
        // Only the dead Mac's deadline passes. The live Mac must connect
        // before its own deadline and before the attempt deadline.
        fixture.macDialDeadlines.expirePending()
        let liveConnected = try await pollUntil {
            fixture.shell.connectionState == .connected
                && fixture.shell.foregroundMacDeviceID == live.deviceID
        }
        let armedDialDeadlines = fixture.macDialDeadlines.armedCount
        // A connected attempt returns on its own; only a starved attempt
        // needs its attempt deadline expired to finish.
        let reconnectReturned = try await pollUntil { result.value != nil }
        fixture.reconnectDeadlines.expirePending()
        await deadRouter.releaseAllHeld()
        await reconnect.value

        #expect(deadDialHasDeadline, "the dead Mac must dial under its own deadline")
        #expect(liveConnected, "the live Mac must connect once the dead Mac's deadline expires")
        #expect(armedDialDeadlines >= 2, "the live Mac must dial under its own deadline")
        #expect(fixture.factory.attemptedRouteIDs().first == dead.routes[0].id)
        #expect(reconnectReturned, "the attempt must finish without its attempt deadline")
        #expect(result.value == true)
        #expect(fixture.shell.foregroundMacDeviceID == live.deviceID)
    }

    /// A full window of discovered Macs that never answer: each dial's own
    /// deadline frees its slot, so the queued live Mac dials and connects
    /// without waiting for the stalled requests or the attempt deadline.
    @Test
    func stalledDiscoveredDialsExpireOnTheirOwnDeadline() async throws {
        let window = ZeroTouchDialRace.maximumConcurrentDials
        let stalled = try (0..<window).map { index in
            try macDialCandidate(
                deviceID: "mac-stalled-\(index)",
                endpointByte: Character(String(index + 1, radix: 16)),
                routeID: "iroh-stalled-\(index)"
            )
        }
        let live = try macDialCandidate(deviceID: "mac-live", endpointByte: "0")
        let fixture = try await MacDialFixture.make(
            macs: stalled + [live],
            discovered: stalled + [live]
        )
        defer { fixture.cleanup() }
        let stalledRouters = try stalled.map { try fixture.router(for: $0) }
        for router in stalledRouters {
            await router.delayHostStatusRequest(number: 1)
        }

        let result = ReconnectResult()
        let reconnect = Task { @MainActor in
            result.value = await fixture.shell.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        let windowHasDeadlines = try await pollUntil {
            for router in stalledRouters where await router.heldRequestCount() != 1 {
                return false
            }
            return fixture.macDialDeadlines.pendingCount == window
        }
        let liveDialedWhileWindowFull = fixture.factory.attemptedRouteIDs()
            .contains(live.routes[0].id)
        fixture.macDialDeadlines.expirePending()
        let liveConnected = try await pollUntil {
            fixture.shell.connectionState == .connected
                && fixture.shell.foregroundMacDeviceID == live.deviceID
        }
        let reconnectReturned = try await pollUntil { result.value != nil }
        fixture.reconnectDeadlines.expirePending()
        for router in stalledRouters {
            await router.releaseAllHeld()
        }
        await reconnect.value

        #expect(windowHasDeadlines, "every stalled discovered dial must run under its own deadline")
        #expect(!liveDialedWhileWindowFull)
        #expect(liveConnected, "expired dials must free their slots for the live Mac")
        #expect(reconnectReturned, "the attempt must finish without its attempt deadline")
        #expect(result.value == true)
        #expect(fixture.shell.foregroundMacDeviceID == live.deviceID)
    }
}

private let macDialFixedNow = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor
private final class ReconnectResult {
    var value: Bool?
}

func macDialCandidate(
    deviceID: String,
    endpointByte: Character,
    routeID: String? = nil
) throws -> MobileDiscoveredIrohMac {
    let endpointID = String(repeating: String(endpointByte), count: 64)
    return MobileDiscoveredIrohMac(
        deviceID: deviceID,
        displayName: "Test \(deviceID)",
        instanceTag: "stable",
        routes: [try CmxAttachRoute(
            id: routeID ?? "iroh-\(deviceID)",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(endpointID: endpointID),
                pathHints: []
            ),
            priority: -10_000
        )],
        lastSeenAt: macDialFixedNow
    )
}

/// One shell over routed Iroh transports, one host router per Mac, with both
/// the reconnect attempt deadline and the per-Mac dial deadline on virtual
/// clocks the test expires explicitly.
@MainActor
struct MacDialFixture {
    let shell: MobileShellComposite
    let store: MobilePairedMacStore
    let factory: RoutedZeroTouchFactory
    let routers: [String: LivenessHostRouter]
    let reconnectDeadlines: ReconnectDeadlineGate
    let macDialDeadlines: ReconnectDeadlineGate
    let directory: URL

    static func make(
        macs: [MobileDiscoveredIrohMac],
        discovered: [MobileDiscoveredIrohMac]
    ) async throws -> MacDialFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        var routers: [String: LivenessHostRouter] = [:]
        for mac in macs {
            let router = LivenessHostRouter()
            await router.setHostIdentity(
                deviceID: mac.deviceID,
                instanceTag: mac.instanceTag,
                displayName: mac.displayName
            )
            routers[mac.routes[0].id] = router
        }
        let factory = RoutedZeroTouchFactory(routers: routers)
        let reconnectDeadlines = ReconnectDeadlineGate()
        let macDialDeadlines = ReconnectDeadlineGate()
        var runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { macDialFixedNow },
            supportedRouteKinds: [.iroh]
        )
        runtime.reconnectDeadlineGate = reconnectDeadlines
        runtime.macDialDeadlineGate = macDialDeadlines
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: store,
            personalIrohDiscovery: ScriptedIrohDiscovery(snapshots: [discovered]),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "iroh-mac-dial-\(UUID().uuidString)"
            )!
        )
        return MacDialFixture(
            shell: shell,
            store: store,
            factory: factory,
            routers: routers,
            reconnectDeadlines: reconnectDeadlines,
            macDialDeadlines: macDialDeadlines,
            directory: directory
        )
    }

    func router(for mac: MobileDiscoveredIrohMac) throws -> LivenessHostRouter {
        try #require(routers[mac.routes[0].id])
    }

    func save(_ mac: MobileDiscoveredIrohMac, active: Bool) async throws {
        try await store.upsert(
            macDeviceID: mac.deviceID,
            displayName: mac.displayName,
            routes: mac.routes,
            instanceTag: mac.instanceTag,
            markActive: active,
            stackUserID: "user-1",
            teamID: nil,
            now: mac.lastSeenAt
        )
    }

    func cleanup() {
        reconnectDeadlines.expirePending()
        macDialDeadlines.expirePending()
        for (_, subscription) in shell.secondaryMacSubscriptions {
            subscription.cancel()
        }
        Task { await shell.remoteClient?.disconnect() }
        try? FileManager.default.removeItem(at: directory)
    }
}
