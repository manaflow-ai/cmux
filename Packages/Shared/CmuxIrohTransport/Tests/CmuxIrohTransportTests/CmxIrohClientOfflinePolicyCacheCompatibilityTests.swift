import Testing
@testable import CmuxIrohTransport

extension CmxIrohClientOfflinePolicyCacheTests {
    @Test("legacy uppercase UUID loads canonical cached target")
    func uppercaseRequestDeviceIDLoadsCanonicalTarget() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let store = TestSecureCredentialStore()
        let cache = CmxIrohClientOfflinePolicyCache(secureStore: store)
        let expectation = try fixture.offlineExpectation()
        try await cache.save(
            localBinding: discovery.bindings[0],
            targetBinding: discovery.bindings[1],
            discovery: discovery,
            pairGrant: fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 3_600
            ),
            for: expectation,
            now: fixture.now
        )

        let loaded = try await cache.load(
            for: fixture.request(
                hints: [],
                expectedPeerDeviceID: fixture.acceptor.deviceID.uppercased()
            ),
            localBinding: discovery.bindings[0],
            expectation: expectation,
            confirmedDiscovery: nil,
            now: fixture.now
        )

        #expect(loaded?.targetBinding == discovery.bindings[1])
    }
}
