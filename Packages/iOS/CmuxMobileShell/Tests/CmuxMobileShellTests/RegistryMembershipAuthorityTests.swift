import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing

@testable import CmuxMobileShell

/// Scriptable registry-list fake: consumes `outcomes` in order (repeating the
/// last), counts calls, and can block a specific call until released so tests
/// can pile presence triggers onto an in-flight fetch.
actor ScriptedDeviceRegistry: DeviceRegistryRefreshing {
    private var outcomes: [DeviceRegistryListOutcome]
    private(set) var listCallCount = 0
    private let blockedCalls: Set<Int>
    private var startedCalls: Set<Int> = []
    private var startWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var blockers: [Int: CheckedContinuation<Void, Never>] = [:]

    init(outcomes: [DeviceRegistryListOutcome], blockedCalls: Set<Int> = []) {
        precondition(!outcomes.isEmpty)
        self.outcomes = outcomes
        self.blockedCalls = blockedCalls
    }

    func freshRoutes(
        forMacDeviceID macDeviceID: String,
        instanceTag: String?
    ) async -> [CmxAttachRoute]? { nil }

    func listDevices() async -> DeviceRegistryListOutcome {
        listCallCount += 1
        let call = listCallCount
        startedCalls.insert(call)
        for waiter in startWaiters.removeValue(forKey: call) ?? [] {
            waiter.resume()
        }
        if blockedCalls.contains(call) {
            await withCheckedContinuation { blockers[call] = $0 }
        }
        return outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
    }

    func waitUntilCallStarted(_ call: Int) async {
        if startedCalls.contains(call) { return }
        await withCheckedContinuation {
            startWaiters[call, default: []].append($0)
        }
    }

    func release(call: Int) {
        blockers.removeValue(forKey: call)?.resume()
    }
}

/// A successful `GET /api/devices` response is the membership authority: a
/// paired Mac absent from it signed out and must leave the device tree, while
/// the paired-store fallback synthesis stays reserved for "the registry is
/// unreachable / not yet fetched" (and local pairing data is never deleted).
@MainActor
@Suite struct RegistryMembershipAuthorityTests {
    @Test func successfulEmptyFetchStopsPairedStoreSynthesis() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-a": [try Self.pairedMac(id: "mac-a", teamID: "team-a")]],
            blockedTeams: []
        )
        let registry = ScriptedDeviceRegistry(outcomes: [.ok([])])
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            deviceRegistry: registry,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        await store.loadPairedMacs()
        // Before the first fetch completes the tree falls back to the local
        // paired store, so a cold start with the cloud slow is never blank.
        #expect(store.deviceTreeDevices.map(\.deviceId) == ["mac-a"])

        await store.loadRegistryDevices()

        // The successful empty response means every Mac signed out: nothing
        // is synthesized back in...
        #expect(store.registryDevicesAreAuthoritative)
        #expect(store.deviceTreeDevices.isEmpty)
        // ...but the local pairing row survives for a later re-sign-in.
        #expect(store.pairedMacs.map(\.macDeviceID) == ["mac-a"])
    }

    @Test func pairedMacAbsentFromSuccessfulResponseLeavesTree() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-a": [try Self.pairedMac(id: "mac-a", teamID: "team-a")]],
            blockedTeams: []
        )
        let registry = ScriptedDeviceRegistry(
            outcomes: [.ok([Self.registryDevice(id: "mac-other")])]
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            deviceRegistry: registry,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        await store.loadPairedMacs()

        await store.loadRegistryDevices()

        // mac-a signed out (absent from the authoritative response); only the
        // registered Mac renders, with no paired-store row merged alongside.
        #expect(store.deviceTreeDevices.map(\.deviceId) == ["mac-other"])
    }

    @Test func transientFailureKeepsPairedStoreFallback() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-a": [try Self.pairedMac(id: "mac-a", teamID: "team-a")]],
            blockedTeams: []
        )
        let registry = ScriptedDeviceRegistry(outcomes: [.transientFailure])
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            deviceRegistry: registry,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        await store.loadPairedMacs()

        await store.loadRegistryDevices()

        // A failed fetch is NOT membership evidence: the tree keeps degrading
        // to the locally paired Macs while the registry is unreachable.
        #expect(!store.registryDevicesAreAuthoritative)
        #expect(store.deviceTreeDevices.map(\.deviceId) == ["mac-a"])
    }

    @Test func authRejectionRestoresPairedStoreFallback() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-a": [try Self.pairedMac(id: "mac-a", teamID: "team-a")]],
            blockedTeams: []
        )
        let registry = ScriptedDeviceRegistry(outcomes: [
            .ok([Self.registryDevice(id: "mac-reg")]),
            .authRejected,
        ])
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            deviceRegistry: registry,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        await store.loadPairedMacs()
        await store.loadRegistryDevices()
        #expect(store.deviceTreeDevices.map(\.deviceId) == ["mac-reg"])

        await store.loadRegistryDevices()

        // 401/403 clears the (possibly other-scope) registry data AND its
        // authority, so the sheet stays usable on local paired Macs (the
        // pre-existing degradation contract).
        #expect(!store.registryDevicesAreAuthoritative)
        #expect(store.registryDevices.isEmpty)
        #expect(store.deviceTreeDevices.map(\.deviceId) == ["mac-a"])
    }

    @Test func teamSwitchResetsMembershipAuthority() async throws {
        let team = MutableTeamID("team-a")
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [try Self.pairedMac(id: "mac-a", teamID: "team-a")],
                "team-b": [try Self.pairedMac(id: "mac-b", teamID: "team-b")],
            ],
            blockedTeams: []
        )
        let registry = ScriptedDeviceRegistry(outcomes: [.ok([])])
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            deviceRegistry: registry,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { await team.value }
        )
        await store.loadPairedMacs()
        await store.loadRegistryDevices()
        #expect(store.registryDevicesAreAuthoritative)
        #expect(store.deviceTreeDevices.isEmpty)

        await team.set("team-b")
        store.currentTeamDidChange()
        await store.loadPairedMacs()

        // The old team's authoritative-empty verdict must not blank the new
        // team's tree before its own first fetch: fallback synthesis resumes.
        #expect(!store.registryDevicesAreAuthoritative)
        #expect(store.deviceTreeDevices.map(\.deviceId) == ["mac-b"])
    }

    @Test func signOutResetsMembershipAuthority() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-a": [try Self.pairedMac(id: "mac-a", teamID: "team-a")]],
            blockedTeams: []
        )
        let registry = ScriptedDeviceRegistry(outcomes: [.ok([])])
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            deviceRegistry: registry,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        await store.loadPairedMacs()
        await store.loadRegistryDevices()
        #expect(store.registryDevicesAreAuthoritative)

        store.signOut()

        #expect(!store.registryDevicesAreAuthoritative)
        #expect(store.deviceTreeDevices.isEmpty)
    }

    private static func pairedMac(id: String, teamID: String) throws -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: id,
            displayName: id,
            routes: [try CmxAttachRoute(
                id: "manual",
                kind: .tailscale,
                endpoint: .hostPort(host: "10.0.0.1", port: 22)
            )],
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 2),
            isActive: false,
            stackUserID: "user-1",
            teamID: teamID
        )
    }

    static func registryDevice(id: String, tag: String = "default") -> RegistryDevice {
        RegistryDevice(
            deviceId: id,
            platform: "mac",
            displayName: id,
            lastSeenAt: Date(timeIntervalSince1970: 2),
            instances: [
                RegistryAppInstance(
                    tag: tag,
                    routes: [],
                    lastSeenAt: Date(timeIntervalSince1970: 2)
                )
            ]
        )
    }
}
