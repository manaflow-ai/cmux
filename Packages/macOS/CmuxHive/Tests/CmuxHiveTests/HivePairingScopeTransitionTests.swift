import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxHive

@MainActor
struct HivePairingScopeTransitionTests {
    private let fixture = HiveDirectoryTestFixture()

    private func legacyLink(deviceID: String) throws -> String {
        let ticket = try CmxAttachTicket(
            workspaceID: "", terminalID: nil, macDeviceID: deviceID,
            macDisplayName: "Test Mac", macUserID: "user-1",
            macPairingCompatibilityVersion: 0,
            routes: [try fixture.tailscaleRoute()], expiresAt: nil
        )
        let data = try CmxAttachTicketCompactCoder().encode(
            ticket, routeDisclosureMode: .legacyPrivateNetworkCompatibility
        )
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(CmxPairingURLScheme.development)://attach?payload=\(payload)"
    }

    @Test func validLinkPairsAfterTeamSwitchRefreshesItsScope() async throws {
        let (store, cleanup) = try fixture.makeTempStore()
        defer { cleanup() }
        let scope = HiveScopeReadGate(scope: HiveAccountScope(stackUserID: "user-1", teamID: "team-1"))
        let directory = HiveComputerDirectory(
            registry: HiveDirectoryTestFixture.Registry(outcome: .ok([])),
            pairedStore: store, presence: nil, ownDeviceID: "self-device",
            scopeProvider: { await scope.read() },
            linkDecoder: HivePairingLinkDecoder(allowsLoopbackRoutes: false),
            presenceRetryDelay: { _ in }
        )
        await directory.refresh()
        await scope.changeScope(to: HiveAccountScope(stackUserID: "user-1", teamID: "team-2"))

        #expect(await directory.pair(link: try legacyLink(deviceID: "mac-b")) == .paired(deviceID: "mac-b"))
        #expect(try await store.loadAll(stackUserID: "user-1", teamID: "team-1").isEmpty)
        let newTeam = try await store.loadAll(stackUserID: "user-1", teamID: "team-2")
        #expect(newTeam.map(\.macDeviceID) == ["mac-b"])
    }

    @Test(arguments: [
        ("self-device", "self-device"),
        ("FCAB639B-4765-4524-B0F9-72329620D51C", "fcab639b-4765-4524-b0f9-72329620d51c")
    ])
    func legacyLinkCannotPairThisMac(deviceID: String, ownDeviceID: String) async throws {
        let (store, cleanup) = try fixture.makeTempStore()
        defer { cleanup() }
        let directory = fixture.makeDirectory(
            registry: .ok([]), store: store, ownDeviceID: ownDeviceID
        )

        #expect(await directory.pair(link: try legacyLink(deviceID: deviceID)) == .loopbackRejected)
        #expect(try await store.loadAll(stackUserID: "user-1", teamID: "team-1").isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func coalescedRefreshLoadsTheNewAccountBeforeReturning() async throws {
        let (store, cleanup) = try fixture.makeTempStore()
        defer { cleanup() }
        let device = RegistryDevice(
            deviceId: "new-team-mac", platform: "mac", displayName: "New Team Mac",
            lastSeenAt: Date(), instances: []
        )
        let registry = HiveGatedRegistry([.ok([]), .ok([device])])
        let scope = HiveScopeReadGate(scope: HiveAccountScope(stackUserID: "user-1", teamID: "team-1"))
        let directory = HiveComputerDirectory(
            registry: registry, pairedStore: store, presence: nil, ownDeviceID: "self-device",
            scopeProvider: { await scope.read() },
            linkDecoder: HivePairingLinkDecoder(allowsLoopbackRoutes: false),
            presenceRetryDelay: { _ in }
        )
        let oldRefresh = Task { await directory.refresh() }
        var firstStarted = registry.started.stream.makeAsyncIterator()
        _ = try #require(await firstStarted.next())
        await scope.changeScope(to: HiveAccountScope(stackUserID: "user-1", teamID: "team-2"))
        let waiting = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let newRefresh = Task {
            waiting.continuation.yield(())
            await directory.refresh()
        }
        var waiterStarted = waiting.stream.makeAsyncIterator()
        _ = try #require(await waiterStarted.next())
        await registry.releaseFirstResponse()
        await oldRefresh.value
        await newRefresh.value

        #expect(await registry.calls == 2)
        #expect(directory.computers.map(\.deviceID) == ["new-team-mac"])
    }

    @Test(.timeLimit(.minutes(1)))
    func anOldRefreshCannotUndoExplicitSignOut() async throws {
        let (store, cleanup) = try fixture.makeTempStore()
        defer { cleanup() }
        let privateMac = RegistryDevice(
            deviceId: "private-mac", platform: "mac", displayName: "Private Mac",
            lastSeenAt: Date(), instances: []
        )
        let registry = HiveGatedRegistry([.ok([privateMac]), .ok([privateMac])])
        let directory = HiveComputerDirectory(
            registry: registry, pairedStore: store, presence: nil, ownDeviceID: "self-device",
            scopeProvider: { HiveAccountScope(stackUserID: "user-1", teamID: "team-1") },
            linkDecoder: HivePairingLinkDecoder(allowsLoopbackRoutes: false),
            presenceRetryDelay: { _ in }
        )
        let pending = Task { await directory.refresh() }
        var started = registry.started.stream.makeAsyncIterator()
        _ = try #require(await started.next())
        directory.clearForSignOut()
        await registry.releaseFirstResponse()
        await pending.value

        #expect(directory.computers.isEmpty)
        #expect(directory.loadedScope == HiveAccountScope(stackUserID: nil, teamID: nil))
        #expect(await registry.calls == 1)
    }
}
