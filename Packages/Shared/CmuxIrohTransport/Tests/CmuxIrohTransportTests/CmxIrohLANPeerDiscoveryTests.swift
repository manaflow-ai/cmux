import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohLANPeerDiscoveryTests {
    @Test
    func browsingIsLazyAndResolvedProfileIsGenerationScoped() async throws {
        let fixture = try Fixture()
        #expect(await fixture.factory.callCount() == 0)

        let discoveryTask = Task {
            await fixture.discovery.discover(
                rendezvous: fixture.rendezvous,
                authenticatedBindings: [fixture.binding],
                expectedMacDeviceID: fixture.binding.deviceID,
                expectedEndpointID: fixture.binding.endpointID,
                timeout: 5
            )
        }
        await fixture.browser.waitUntilStarted()
        #expect(await fixture.factory.callCount() == 1)
        await fixture.browser.emit(.resolved(fixture.serviceID, fixture.service))

        guard case let .found(peers) = await discoveryTask.value else {
            Issue.record("Expected an authenticated LAN result")
            return
        }
        let peer = try #require(peers.first)
        #expect(peer.binding == fixture.binding)
        #expect(peer.pathGeneration == 1)
        #expect(await fixture.path.snapshot().activeNetworkProfiles == [peer.networkProfile])
    }

    @Test
    func developmentBindingQuotaStillAllowsPinnedLANDiscovery() async throws {
        let fixture = try Fixture()
        let path = fixture.path
        let discovery = CmxIrohLANPeerDiscovery(
            browserFactory: {
                PreloadedLANBrowser(
                    event: .resolved(fixture.serviceID, fixture.service)
                )
            },
            interfaces: TestLANInterfaces(values: [
                try CmxIrohLANInterfaceAddress(
                    interfaceIndex: 4,
                    ipAddress: "192.168.1.22",
                    netmask: "255.255.255.0"
                ),
            ]),
            clock: TestLANClock(now: fixture.date),
            networkPath: { await path.snapshot() },
            authorizeProfile: { profile, generation, interfaceIndex in
                await path.authorize(
                    profile: profile,
                    generation: generation,
                    interfaceIndex: interfaceIndex
                )
            },
            revokeProfile: { profile, generation in
                await path.revoke(profile: profile, generation: generation)
            }
        )
        let unrelated = try (1 ... 32).map { index in
            try CmxIrohBrokerBindingMetadata(
                bindingID: String(
                    format: "323e4567-e89b-42d3-a456-%012d",
                    index
                ),
                deviceID: String(
                    format: "423e4567-e89b-42d3-a456-%012d",
                    index
                ),
                appInstanceID: String(
                    format: "523e4567-e89b-42d3-a456-%012d",
                    index
                ),
                tag: "test-\(index)",
                platform: .mac,
                endpointID: CmxIrohPeerIdentity(
                    endpointID: String(format: "%064llx", UInt64(index + 1))
                ),
                identityGeneration: 1
            )
        }
        let outcome = await discovery.discover(
            rendezvous: fixture.rendezvous,
            authenticatedBindings: [fixture.binding] + unrelated,
            expectedMacDeviceID: fixture.binding.deviceID,
            expectedEndpointID: fixture.binding.endpointID,
            timeout: 0.2
        )

        guard case let .found(peers) = outcome else {
            Issue.record("Expected pinned LAN discovery within development quota")
            return
        }
        #expect(peers.map(\.binding) == [fixture.binding])
    }

    @Test
    func removalRevokesAuthorizationAndOldHintsCannotSurvive() async throws {
        let fixture = try Fixture()
        let discoveryTask = Task {
            await fixture.discovery.discover(
                rendezvous: fixture.rendezvous,
                authenticatedBindings: [fixture.binding],
                expectedMacDeviceID: fixture.binding.deviceID,
                expectedEndpointID: fixture.binding.endpointID,
                timeout: 5
            )
        }
        await fixture.browser.waitUntilStarted()
        await fixture.browser.emit(.resolved(fixture.serviceID, fixture.service))
        guard case .found = await discoveryTask.value else {
            Issue.record("Expected initial result")
            return
        }

        await fixture.browser.emit(.removed(fixture.serviceID))
        await fixture.path.waitForRevocation()

        #expect(await fixture.path.snapshot().activeNetworkProfiles.isEmpty)
        #expect(await fixture.path.revocationCount() == 1)
    }

    @Test
    func pathChangeRevokesProfilesStopsBrowseAndRequiresNewGeneration() async throws {
        let fixture = try Fixture()
        let discoveryTask = Task {
            await fixture.discovery.discover(
                rendezvous: fixture.rendezvous,
                authenticatedBindings: [fixture.binding],
                expectedMacDeviceID: fixture.binding.deviceID,
                expectedEndpointID: fixture.binding.endpointID,
                timeout: 5
            )
        }
        await fixture.browser.waitUntilStarted()
        await fixture.browser.emit(.resolved(fixture.serviceID, fixture.service))
        guard case let .found(peers) = await discoveryTask.value,
              let previous = peers.first else {
            Issue.record("Expected initial result")
            return
        }

        await fixture.path.advanceGeneration()
        await fixture.discovery.pathDidChange()

        let snapshot = await fixture.path.snapshot()
        #expect(snapshot.generation == 2)
        #expect(snapshot.activeNetworkProfiles.isEmpty)
        #expect(!snapshot.activeNetworkProfiles.contains(previous.networkProfile))
        #expect(await fixture.browser.wasStopped())
    }

    @Test
    func policyDeniedIsDistinctAndDoesNotThrowOrAuthorize() async throws {
        let fixture = try Fixture()
        let discoveryTask = Task {
            await fixture.discovery.discover(
                rendezvous: fixture.rendezvous,
                authenticatedBindings: [fixture.binding],
                expectedMacDeviceID: fixture.binding.deviceID,
                expectedEndpointID: fixture.binding.endpointID,
                timeout: 5
            )
        }
        await fixture.browser.waitUntilStarted()
        await fixture.browser.emit(.policyDenied)

        #expect(await discoveryTask.value == .policyDenied)
        #expect(await fixture.path.snapshot().activeNetworkProfiles.isEmpty)
        #expect(await fixture.browser.wasStopped())
    }

    @Test
    func foregroundPermissionResetIsLazyAndNextExplicitDiscoveryCanRetry() async throws {
        let fixture = try Fixture()
        let deniedTask = Task {
            await fixture.discovery.discover(
                rendezvous: fixture.rendezvous,
                authenticatedBindings: [fixture.binding],
                expectedMacDeviceID: fixture.binding.deviceID,
                expectedEndpointID: fixture.binding.endpointID,
                timeout: 5
            )
        }
        await fixture.browser.waitUntilStarted()
        await fixture.browser.emit(.policyDenied)
        #expect(await deniedTask.value == .policyDenied)
        #expect(await fixture.factory.callCount() == 1)

        await fixture.discovery.permissionMayHaveChanged()

        #expect(await fixture.factory.callCount() == 1)
        let retryTask = Task {
            await fixture.discovery.discover(
                rendezvous: fixture.rendezvous,
                authenticatedBindings: [fixture.binding],
                expectedMacDeviceID: fixture.binding.deviceID,
                expectedEndpointID: fixture.binding.endpointID,
                timeout: 5
            )
        }
        await fixture.browser.waitUntilStarted()
        await fixture.browser.emit(.resolved(fixture.serviceID, fixture.service))

        guard case .found = await retryTask.value else {
            Issue.record("Expected explicit reconnect to retry Bonjour")
            return
        }
        #expect(await fixture.factory.callCount() == 2)
    }

    @Test
    func unknownOrUnpairedAliasCannotCreateAProfile() async throws {
        let fixture = try Fixture()
        let otherBinding = try fixture.makeBinding(endpointByte: "b")
        let otherAdvertisement = try #require(CmxIrohLANAdvertisementBuilder().advertisements(
            rendezvous: fixture.rendezvous,
            binding: otherBinding,
            directAddresses: ["192.168.1.10:50906"],
            interfaces: [fixture.hostInterface],
            at: fixture.date
        ).first)
        let otherID = CmxIrohBonjourServiceID(
            serviceName: otherAdvertisement.alias,
            interfaceIndex: otherAdvertisement.interfaceIndex
        )
        let task = Task {
            await fixture.discovery.discover(
                rendezvous: fixture.rendezvous,
                authenticatedBindings: [fixture.binding],
                expectedMacDeviceID: fixture.binding.deviceID,
                expectedEndpointID: fixture.binding.endpointID,
                timeout: 0.05
            )
        }
        await fixture.browser.waitUntilStarted()
        await fixture.browser.emit(.resolved(
            otherID,
            CmxIrohBonjourResolvedService(
                serviceName: otherAdvertisement.alias,
                hostTarget: otherAdvertisement.hostTarget,
                interfaceIndex: otherAdvertisement.interfaceIndex,
                port: otherAdvertisement.port,
                txtRecord: otherAdvertisement.txtRecord
            )
        ))

        #expect(await task.value == .notFound)
        #expect(await fixture.path.snapshot().activeNetworkProfiles.isEmpty)
    }
}

private struct PreloadedLANBrowser: CmxIrohBonjourBrowsing {
    let event: CmxIrohBonjourBrowserEvent

    func events() async -> AsyncStream<CmxIrohBonjourBrowserEvent> {
        AsyncStream { continuation in
            continuation.yield(event)
            continuation.finish()
        }
    }

    func stop() async {}
}

private struct TestLANInterfaces: CmxIrohLANInterfaceSnapshotProviding {
    let values: [CmxIrohLANInterfaceAddress]
    func interfaceAddresses() throws -> [CmxIrohLANInterfaceAddress] { values }
}

private actor TestLANBrowser: CmxIrohBonjourBrowsing {
    private var continuation: AsyncStream<CmxIrohBonjourBrowserEvent>.Continuation?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopped = false

    func events() -> AsyncStream<CmxIrohBonjourBrowserEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func stop() {
        stopped = true
        continuation?.finish()
        continuation = nil
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func emit(_ event: CmxIrohBonjourBrowserEvent) {
        continuation?.yield(event)
    }

    func wasStopped() -> Bool { stopped }
}

private actor TestLANBrowserFactoryRecorder {
    private let browser: TestLANBrowser
    private var calls = 0

    init(browser: TestLANBrowser) {
        self.browser = browser
    }

    nonisolated func make() -> any CmxIrohBonjourBrowsing {
        Task { await recordCall() }
        return browser
    }

    private func recordCall() { calls += 1 }
    func callCount() -> Int { calls }
}

private actor TestLANPathState {
    private var generation: UInt64 = 1
    private var profiles: Set<CmxIrohNetworkProfileKey> = []
    private var revocations = 0
    private var revocationWaiters: [CheckedContinuation<Void, Never>] = []

    func snapshot() -> CmxIrohNetworkPathSnapshot {
        CmxIrohNetworkPathSnapshot(
            generation: generation,
            activeNetworkProfiles: profiles
        )
    }

    func authorize(
        profile: CmxIrohNetworkProfileKey,
        generation expectedGeneration: UInt64,
        interfaceIndex: UInt32
    ) -> Bool {
        guard expectedGeneration == generation, interfaceIndex == 4 else { return false }
        profiles.insert(profile)
        return true
    }

    func revoke(
        profile: CmxIrohNetworkProfileKey,
        generation expectedGeneration: UInt64
    ) {
        if expectedGeneration <= generation { profiles.remove(profile) }
        revocations += 1
        let waiters = revocationWaiters
        revocationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func advanceGeneration() {
        generation &+= 1
        profiles.removeAll()
    }

    func waitForRevocation() async {
        if revocations > 0 { return }
        await withCheckedContinuation { revocationWaiters.append($0) }
    }

    func revocationCount() -> Int { revocations }
}

private struct Fixture {
    let date = Date(timeIntervalSince1970: 1_800_000_001)
    let rendezvous: CmxIrohLANRendezvous
    let binding: CmxIrohBrokerBindingMetadata
    let hostInterface: CmxIrohLANInterfaceAddress
    let serviceID: CmxIrohBonjourServiceID
    let service: CmxIrohBonjourResolvedService
    let browser: TestLANBrowser
    let factory: TestLANBrowserFactoryRecorder
    let path: TestLANPathState
    let discovery: CmxIrohLANPeerDiscovery

    init() throws {
        let key = Data(repeating: 7, count: 32)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let data = try JSONSerialization.data(withJSONObject: [
            "generation": 3,
            "key": key,
        ])
        rendezvous = try JSONDecoder().decode(CmxIrohLANRendezvous.self, from: data)
        binding = try Self.binding(endpointByte: "a")
        hostInterface = try CmxIrohLANInterfaceAddress(
            interfaceIndex: 4,
            ipAddress: "192.168.1.10",
            netmask: "255.255.255.0"
        )
        let advertisement = try #require(CmxIrohLANAdvertisementBuilder().advertisements(
            rendezvous: rendezvous,
            binding: binding,
            directAddresses: ["192.168.1.10:50906"],
            interfaces: [hostInterface],
            at: date
        ).first)
        serviceID = CmxIrohBonjourServiceID(
            serviceName: advertisement.alias,
            interfaceIndex: advertisement.interfaceIndex
        )
        service = CmxIrohBonjourResolvedService(
            serviceName: advertisement.alias,
            hostTarget: advertisement.hostTarget,
            interfaceIndex: advertisement.interfaceIndex,
            port: advertisement.port,
            txtRecord: advertisement.txtRecord
        )
        browser = TestLANBrowser()
        factory = TestLANBrowserFactoryRecorder(browser: browser)
        path = TestLANPathState()
        let clientInterface = try CmxIrohLANInterfaceAddress(
            interfaceIndex: 4,
            ipAddress: "192.168.1.22",
            netmask: "255.255.255.0"
        )
        let factory = factory
        let path = path
        discovery = CmxIrohLANPeerDiscovery(
            browserFactory: { factory.make() },
            interfaces: TestLANInterfaces(values: [clientInterface]),
            clock: TestLANClock(now: date),
            networkPath: { await path.snapshot() },
            authorizeProfile: { profile, generation, interfaceIndex in
                await path.authorize(
                    profile: profile,
                    generation: generation,
                    interfaceIndex: interfaceIndex
                )
            },
            revokeProfile: { profile, generation in
                await path.revoke(profile: profile, generation: generation)
            }
        )
    }

    func makeBinding(endpointByte: Character) throws -> CmxIrohBrokerBindingMetadata {
        try Self.binding(endpointByte: endpointByte)
    }

    private static func binding(endpointByte: Character) throws -> CmxIrohBrokerBindingMetadata {
        try CmxIrohBrokerBindingMetadata(
            bindingID: endpointByte == "a"
                ? "123e4567-e89b-42d3-a456-426614174010"
                : "123e4567-e89b-42d3-a456-426614174020",
            deviceID: endpointByte == "a"
                ? "123e4567-e89b-42d3-a456-426614174011"
                : "123e4567-e89b-42d3-a456-426614174021",
            appInstanceID: endpointByte == "a"
                ? "123e4567-e89b-42d3-a456-426614174012"
                : "123e4567-e89b-42d3-a456-426614174022",
            tag: "test",
            platform: .mac,
            endpointID: CmxIrohPeerIdentity(
                endpointID: String(repeating: endpointByte, count: 64)
            ),
            identityGeneration: 1
        )
    }
}

private struct TestLANClock: CmxIrohLANClock {
    let value: Date

    init(now: Date) { value = now }
    func now() -> Date { value }
    func sleep(for interval: TimeInterval) async throws {
        let milliseconds = Int64(interval * 1_000)
        try await ContinuousClock().sleep(for: .milliseconds(milliseconds))
    }
}
