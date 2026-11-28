import Testing
import CmuxMobileRPC
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileTaskDirectorySearchTests {
    @Test func liveSearchDoesNotTrustStaleMissingCapabilityMetadata() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: []
        )

        let result = await store.searchTaskDirectories(
            macDeviceID: "test-mac",
            query: "  cmux  "
        )

        #expect(await router.recordedDirectorySearchQueries() == ["cmux"])
        #expect(
            result == .success(MobileTaskDirectorySearchResponse(
                directories: [
                    "/Users/test/Dev/Manaflow/cmux",
                    "/Users/test/Dev/Manaflow/cmuxterm-hq",
                ]
            ))
        )
    }

    @Test func liveSearchSurfacesTimeoutForRetry() async throws {
        let router = RoutingHostRouter()
        await router.setDirectorySearchError(
            code: "request_timeout",
            message: "Directory search timed out"
        )
        let store = try await makeRoutingConnectedStore(router: router)

        let result = await store.searchTaskDirectories(macDeviceID: "test-mac", query: "cmux")

        #expect(result == .failure(.timedOut))
    }

    @Test func olderHostWithoutSearchMethodSurfacesUnsupportedSearch() async throws {
        let router = RoutingHostRouter()
        await router.setDirectorySearchError(code: "method_not_found", message: "Unknown method")
        let store = try await makeRoutingConnectedStore(router: router)

        let result = await store.searchTaskDirectories(macDeviceID: "test-mac", query: "cmux")

        #expect(result == .failure(.unsupported))
    }
}
