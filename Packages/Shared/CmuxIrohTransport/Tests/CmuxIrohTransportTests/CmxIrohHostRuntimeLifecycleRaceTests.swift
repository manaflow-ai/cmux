import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

extension CmxIrohHostRuntimeTests {
    @Test("relay installation republishes the host's newly usable address")
    func relayInstallationRepublishesNewlyAddressedHost() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try HostRuntimeFixture(now: now)
        let refreshedBinding = try HostRuntimeFixture.binding(
            endpointID: fixture.endpointID.endpointID,
            bindingID: fixture.binding.bindingID,
            publicHintObservedAt: now,
            publicHintExpiresAt: now.addingTimeInterval(60 * 60)
        )
        let relayHint = try #require(refreshedBinding.pathHints.first)
        let refreshedDiscovery = try HostRuntimeFixture.discovery(
            binding: refreshedBinding,
            relays: HostRuntimeFixture.relayURLs
        )
        let endpoint = TestIrohEndpoint(
            identity: fixture.endpointID,
            directAddresses: ["0.0.0.0:50909", "[::]:54750"],
            pathHintsAfterRelayReplacement: [relayHint]
        )
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            subsequentRegistrationBindings: [refreshedBinding],
            subsequentDiscoveries: [refreshedDiscovery]
        )
        let publications = HostRuntimeBindingPublicationRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { now },
            handleTransport: { session, _ in await session.close() },
            handleBinding: { registration, discovery, _ in
                await publications.record(
                    registration: registration.binding,
                    discovery: discovery
                )
            }
        )
        try await runtime.start()

        let republished = await broker.waitForRegistrationCount(
            2,
            timeout: .seconds(1)
        )
        #expect(
            republished,
            "Installing the first usable relay address must request a fresh registration"
        )
        guard republished else {
            await runtime.stop()
            return
        }

        let registrations = await broker.observedPreparedRegistrations()
        #expect(registrations.count == 2)
        let initialHints = try registrationPathHints(registrations[0])
        let refreshedHints = try registrationPathHints(registrations[1])
        #expect(initialHints.isEmpty)
        #expect(refreshedHints == [relayHint])
        let expectedDirectPorts = try CmxIrohDirectPorts(
            ipv4: 50_909,
            ipv6: 54_750
        )
        let initialDirectPorts = try registrationDirectPorts(registrations[0])
        let refreshedDirectPorts = try registrationDirectPorts(registrations[1])
        #expect(initialDirectPorts == expectedDirectPorts)
        #expect(refreshedDirectPorts == expectedDirectPorts)

        let published = await publications.values()
        #expect(published.count == 2)
        #expect(published[0].registration.pathHints.isEmpty)
        #expect(published[0].discovered.pathHints.isEmpty)
        #expect(published[1].registration.pathHints == [relayHint])
        #expect(published[1].discovered.pathHints == [relayHint])
        #expect(published[1].registration.endpointID == fixture.endpointID)
        #expect(published[1].registration.bindingID == fixture.binding.bindingID)

        let snapshot = await runtime.snapshot()
        #expect(snapshot.state == .active)
        #expect(snapshot.endpointID == fixture.endpointID)
        #expect(snapshot.bindingID == fixture.binding.bindingID)
        #expect(await endpoint.observedCloseCallCount() == 0)
        await runtime.stop()
    }

    @Test
    func validatedBindingPublishesBeforeRelayCredentialInstallationCompletes() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let gate = HostRuntimeSuspensionGate()
        let bindings = HostRuntimeBindingRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohHostBroker(
                registrationBinding: fixture.binding,
                discovery: fixture.discovery,
                relayIssueHook: { await gate.suspend() }
            ),
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() },
            handleBinding: { _, _, _ in await bindings.record() }
        )
        let start = Task { try await runtime.start() }
        await gate.waitUntilSuspended()

        #expect(await bindings.count() == 1)

        await gate.resume()
        try await start.value
        await runtime.stop()
    }

    @Test
    func validatedBindingPublishesBeforeLANAdvertisementCompletes() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let gate = HostRuntimeSuspensionGate()
        let bindings = HostRuntimeBindingRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohHostBroker(
                registrationBinding: fixture.binding,
                discovery: fixture.discovery
            ),
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() },
            handleBinding: { _, _, _ in await bindings.record() },
            handleLANPolicy: { _, _ in await gate.suspend() }
        )
        let start = Task { try await runtime.start() }
        await gate.waitUntilSuspended()

        #expect(await bindings.count() == 1)

        await gate.resume()
        try await start.value
        await runtime.stop()
    }

    @Test
    func stoppedHostIgnoresSupersededRefreshFailure() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let gate = HostRuntimeRegistrationGate()
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            subsequentRegistrationHook: { await gate.waitOnce() }
        )
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() }
        )
        try await runtime.start()
        await endpoint.emit(.networkChanged)
        await broker.waitForRegistrationCount(2)
        let refresh = await runtime.registrationRefreshTask

        await runtime.stop()
        await gate.open()
        await refresh?.value

        #expect(await runtime.snapshot().state == .inactive)
        #expect(await endpoint.observedCloseCallCount() == 1)
    }

    @Test
    func signedOutHostIgnoresSupersededRefreshFailure() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let gate = HostRuntimeRegistrationGate()
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            subsequentRegistrationHook: { await gate.waitOnce() }
        )
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() }
        )
        try await runtime.start()
        await endpoint.emit(.networkChanged)
        await broker.waitForRegistrationCount(2)
        let refresh = await runtime.registrationRefreshTask

        let preparation = await runtime.deactivateForSignOut()
        await gate.open()
        await refresh?.value

        #expect(preparation.wasPersisted)
        #expect(await runtime.snapshot().state == .inactive)
        #expect(await endpoint.observedCloseCallCount() == 1)
    }
}

private struct HostRuntimeBindingPublication: Equatable, Sendable {
    let registration: CmxIrohBrokerBinding
    let discovered: CmxIrohBrokerBinding
}

private actor HostRuntimeBindingPublicationRecorder {
    private var recorded: [HostRuntimeBindingPublication] = []

    func record(
        registration: CmxIrohBrokerBinding,
        discovery: CmxIrohDiscoveryResponse
    ) {
        guard let discovered = discovery.bindings.first(where: {
            $0.bindingID == registration.bindingID
        }) else { return }
        recorded.append(
            HostRuntimeBindingPublication(
                registration: registration,
                discovered: discovered
            )
        )
    }

    func values() -> [HostRuntimeBindingPublication] { recorded }
}

private func registrationPathHints(
    _ prepared: CmxIrohPreparedRegistration
) throws -> [CmxIrohPathHint] {
    let value = prepared.encodedPayload
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let padded = value + String(repeating: "=", count: (4 - value.count % 4) % 4)
    let payload = try #require(Data(base64Encoded: padded))
    let object = try #require(
        JSONSerialization.jsonObject(with: payload) as? [String: Any]
    )
    let pathHints = try #require(object["pathHints"] as? [[String: Any]])
    let encodedHints = try JSONSerialization.data(withJSONObject: pathHints)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode([CmxIrohPathHint].self, from: encodedHints)
}

private func registrationDirectPorts(
    _ prepared: CmxIrohPreparedRegistration
) throws -> CmxIrohDirectPorts? {
    let value = prepared.encodedPayload
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let padded = value + String(repeating: "=", count: (4 - value.count % 4) % 4)
    let payload = try #require(Data(base64Encoded: padded))
    let object = try #require(
        JSONSerialization.jsonObject(with: payload) as? [String: Any]
    )
    guard let directPorts = object["directPorts"] else { return nil }
    return try JSONDecoder().decode(
        CmxIrohDirectPorts.self,
        from: JSONSerialization.data(withJSONObject: directPorts)
    )
}

private actor HostRuntimeSuspensionGate {
    private var suspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        suspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { resumeWaiter = $0 }
    }

    func waitUntilSuspended() async {
        if suspended { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func resume() {
        resumeWaiter?.resume()
        resumeWaiter = nil
    }
}
