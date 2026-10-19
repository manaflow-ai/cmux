import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
private final class RecoveryForgetStub: MobileIrohMacForgetting {
    private(set) var forgottenIDs: [String] = []

    func forgetComputer(
        macDeviceID: String,
        instanceTag _: String?,
        expectedAccountID _: String
    ) async throws {
        forgottenIDs.append(macDeviceID)
    }
}

@MainActor
private final class RecoveryDirectoryStub: MobileIrohMacDiscovering {
    var candidates: [MobileDiscoveredIrohMac]
    private(set) var invalidatedIDs: [String] = []
    private var blockedDiscovery = false
    private var discoveryStarted = false
    private var discoveryCount = 0
    private var discoveryStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var discoveryCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var discoveryRelease: CheckedContinuation<Void, Never>?

    init(candidates: [MobileDiscoveredIrohMac]) {
        self.candidates = candidates
    }

    func discoverLiveMacs() async -> [MobileDiscoveredIrohMac] {
        let snapshot = candidates
        discoveryCount += 1
        discoveryStarted = true
        let startWaiters = discoveryStartWaiters
        discoveryStartWaiters.removeAll()
        for waiter in startWaiters { waiter.resume() }
        let countWaiters = discoveryCountWaiters.filter { discoveryCount >= $0.0 }
        discoveryCountWaiters.removeAll { discoveryCount >= $0.0 }
        for (_, waiter) in countWaiters { waiter.resume() }
        if blockedDiscovery {
            blockedDiscovery = false
            await withCheckedContinuation { continuation in
                discoveryRelease = continuation
            }
        }
        return snapshot
    }

    func invalidateDiscovery(forMacDeviceID deviceID: String) async {
        invalidatedIDs.append(deviceID)
    }

    func replaceCandidates(_ candidates: [MobileDiscoveredIrohMac]) {
        self.candidates = candidates
    }

    func blockNextDiscovery() {
        blockedDiscovery = true
        discoveryStarted = false
    }

    func waitUntilDiscoveryStarted() async {
        if discoveryStarted { return }
        await withCheckedContinuation { discoveryStartWaiters.append($0) }
    }

    func waitUntilDiscoveryCount(_ count: Int) async {
        if discoveryCount >= count { return }
        await withCheckedContinuation { discoveryCountWaiters.append((count, $0)) }
    }

    func releaseDiscovery() {
        discoveryRelease?.resume()
        discoveryRelease = nil
    }
}

@MainActor
@Suite struct MobileShellCompositeForgottenMacRecoveryTests {
    @Test func rehydratesAfterForgetFromAuthenticatedDirectoryAndCoalescesDuplicates() async throws {
        let macID = "123e4567-e89b-12d3-a456-426614174000"
        let suiteName = "forgotten-mac-recovery-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // Seed the tagged row first so inserting the legacy unclaimed row does
        // not claim it as Nightly during the store's normal identity migration.
        for tag: String? in ["nightly", nil] {
            try await pairedStore.upsert(
                macDeviceID: macID,
                displayName: tag == nil ? "Legacy Mac" : "Nightly Mac",
                routes: [],
                instanceTag: tag,
                markActive: false,
                stackUserID: "user-1",
                teamID: "team-a",
                now: Date(timeIntervalSince1970: 2)
            )
        }
        let route = try CmxAttachRoute(
            id: "iroh-recovered",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)),
                pathHints: []
            )
        )
        let recoveredCandidates = [
            MobileDiscoveredIrohMac(
                deviceID: macID.uppercased(),
                displayName: "Recovered Mac",
                instanceTag: "default",
                routes: [route],
                lastSeenAt: Date(timeIntervalSince1970: 10)
            ),
            // Older directory snapshots could contain the same physical id with
            // different casing. The recovery projection must create one row.
            MobileDiscoveredIrohMac(
                deviceID: macID,
                displayName: "Duplicate Mac",
                instanceTag: "default",
                routes: [route],
                lastSeenAt: Date(timeIntervalSince1970: 10)
            ),
            MobileDiscoveredIrohMac(
                deviceID: macID,
                displayName: "Recovered Nightly Mac",
                instanceTag: "nightly",
                routes: [route],
                lastSeenAt: Date(timeIntervalSince1970: 10)
            ),
        ]
        let discovery = RecoveryDirectoryStub(candidates: [])
        let forget = RecoveryForgetStub()
        let shell = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            personalIrohDiscovery: discovery,
            personalIrohForget: forget,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            pairingHintDefaults: defaults,
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )

        await shell.loadPairedMacs()
        let beforeForget = try await pairedStore.loadAllInstances(
            macDeviceID: macID,
            stackUserID: "user-1"
        )
        #expect(beforeForget.count == 2)
        #expect(Set(beforeForget.map(\.instanceTag)) == Set([nil, "nightly"]))
        await shell.hideMac(macDeviceID: macID)
        let hidden = try #require(shell.hiddenComputers.first { $0.instanceTag == nil })

        #expect(await shell.forgetHiddenComputer(hidden))
        #expect(forget.forgottenIDs == [macID])
        #expect(discovery.invalidatedIDs == [macID])
        let afterForget = try await pairedStore.loadAll(
            stackUserID: "user-1",
            teamID: "team-a"
        )
        #expect(afterForget.isEmpty)
        let rememberedIDs = try #require(
            defaults.array(forKey: "cmux.mobile.forgottenMacRecovery.user-1") as? [String]
        )
        #expect(Set(rememberedIDs) == Set([
            MobilePairedMac.pairingID(macDeviceID: macID, instanceTag: nil),
            MobilePairedMac.pairingID(macDeviceID: macID, instanceTag: "nightly"),
        ]))

        // The Mac can publish after the revoke's immediate refresh. The
        // directory update path must consume the durable recovery identity.
        discovery.replaceCandidates(recoveredCandidates)
        await shell.recoverForgottenMacsFromDirectory(
            scope: MobileShellScopeSnapshot(
                userID: "user-1",
                teamID: "team-a",
                generation: 0
            ),
            refreshDirectory: false
        )

        let recovered = try await pairedStore.loadAll(
            stackUserID: "user-1",
            teamID: "team-a"
        )
        #expect(recovered.count == 2)
        let recoveredStable = try #require(recovered.first { $0.instanceTag == "default" })
        let recoveredNightly = try #require(recovered.first { $0.instanceTag == "nightly" })
        #expect(recoveredStable.macDeviceID == macID)
        #expect(recoveredStable.displayName == "Recovered Mac")
        #expect(recoveredNightly.macDeviceID == macID)
        #expect(recoveredNightly.displayName == "Recovered Nightly Mac")
        #expect(shell.pairedMacs.count == 2)
    }

    @Test func preservesASecondForgetWhileRecoveryDirectoryFetchIsInFlight() async throws {
        let suiteName = "forgotten-mac-recovery-race-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        for macID in ["mac-a", "mac-b"] {
            try await pairedStore.upsert(
                macDeviceID: macID,
                displayName: "Desk \(macID)",
                routes: [],
                markActive: false,
                stackUserID: "user-1",
                teamID: "team-a",
                now: Date(timeIntervalSince1970: 2)
            )
        }
        let route = try CmxAttachRoute(
            id: "iroh-recovered",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(endpointID: String(repeating: "b", count: 64)),
                pathHints: []
            )
        )
        let candidates = [
            MobileDiscoveredIrohMac(
                deviceID: "mac-a",
                displayName: "Recovered Mac A",
                instanceTag: "",
                routes: [route],
                lastSeenAt: Date(timeIntervalSince1970: 10)
            ),
            MobileDiscoveredIrohMac(
                deviceID: "mac-b",
                displayName: "Recovered Mac B",
                instanceTag: "",
                routes: [route],
                lastSeenAt: Date(timeIntervalSince1970: 11)
            ),
        ]
        let discovery = RecoveryDirectoryStub(candidates: [candidates[0]])
        let forget = RecoveryForgetStub()
        let shell = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            personalIrohDiscovery: discovery,
            personalIrohForget: forget,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            pairingHintDefaults: defaults,
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )

        await shell.loadPairedMacs()
        await shell.hideMac(macDeviceID: "mac-a")
        await shell.hideMac(macDeviceID: "mac-b")
        let hiddenA = try #require(shell.hiddenComputers.first { $0.macDeviceID == "mac-a" })
        let hiddenB = try #require(shell.hiddenComputers.first { $0.macDeviceID == "mac-b" })
        discovery.blockNextDiscovery()

        let firstForget = Task { @MainActor in
            await shell.forgetHiddenComputer(hiddenA)
        }
        await discovery.waitUntilDiscoveryStarted()

        // The second forget completes cleanup while the first directory read is
        // suspended. Its recovery request must be queued rather than dropped.
        let secondForget = Task { @MainActor in
            await shell.forgetHiddenComputer(hiddenB)
        }
        #expect(await secondForget.value)
        discovery.replaceCandidates(candidates)
        discovery.releaseDiscovery()
        #expect(await firstForget.value)

        // The queued rerun observes the second Mac in the next authenticated
        // snapshot and consumes its marker.
        await discovery.waitUntilDiscoveryCount(2)
        let recovered = try await pairedStore.loadAll(
            stackUserID: "user-1",
            teamID: "team-a"
        )
        #expect(Set(recovered.map(\.macDeviceID)) == Set(["mac-a", "mac-b"]))
        #expect(recovered.count == 2)
    }

}
