import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileTaskDirectorySearchTests {
    @Test func liveSearchDoesNotTrustStaleMissingCapabilityMetadata() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: []
        )

        let directories = await store.searchTaskDirectories(
            macDeviceID: "test-mac",
            query: "  cmux  "
        )

        #expect(await router.recordedDirectorySearchQueries() == ["cmux"])
        #expect(directories == [
            "/Users/test/Dev/Manaflow/cmux",
            "/Users/test/Dev/Manaflow/cmuxterm-hq",
        ])
    }
}
