import CMUXMobileCore
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohClientRuntimeEmptyFleetTests {
    /// A device whose relay policy is unavailable (empty managed fleet) must
    /// still activate for registration and direct paths instead of failing
    /// the offline-policy expectation before any broker call. Field reports
    /// showed this as an unclassified `endpointFailed` immediately after a
    /// rate-limited policy refresh, which made reconnection impossible even
    /// on the local network.
    @Test
    func startWithEmptyManagedFleetAndOfflineCacheActivatesForDirectPaths() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            relay: fixture.relayResponse()
        )
        let recorder = ClientRuntimeTestRecorder()
        let configuration = CmxIrohClientRuntimeConfiguration(
            accountID: fixture.configuration.accountID,
            deviceID: fixture.configuration.deviceID,
            appInstanceID: fixture.configuration.appInstanceID,
            tag: fixture.configuration.tag,
            displayName: fixture.configuration.displayName,
            identity: fixture.identity,
            capabilities: fixture.configuration.capabilities,
            managedRelayURLs: []
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: configuration,
            pendingRevocations: fixture.pendingRevocations(),
            offlinePolicyCache: CmxIrohClientOfflinePolicyCache(
                secureStore: TestSecureCredentialStore()
            ),
            now: { fixture.now },
            handleBinding: { _, _ in
                await recorder.recordBinding()
                return true
            },
            handleRelayCredential: { _, _ in await recorder.recordRelay() }
        )

        try await runtime.start()

        #expect(await runtime.snapshot().state == .active)
        #expect(await broker.observedRegistrations().isEmpty == false)
    }
}
