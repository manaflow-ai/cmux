import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileTaskDirectoryListTests {
    @Test func browseSendsTypedPaginationAndDecodesEntries() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)

        let result = await store.listTaskDirectories(
            macDeviceID: "test-mac",
            path: "~",
            offset: 0,
            limit: 1
        )

        let page = try #require(result.successValue)
        #expect(page.currentPath == "/Users/test")
        #expect(page.entries.map(\.name) == [".hidden"])
        #expect(page.entries.first?.isHidden == true)
        #expect(page.totalCount == 2)
        #expect(page.nextOffset == 1)
        let requests = await router.recordedDirectoryListRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.path == "~")
        #expect(requests.first?.offset == 0)
        #expect(requests.first?.limit == 1)
    }

    @Test func olderHostMapsMissingMethodToUnsupported() async throws {
        let router = RoutingHostRouter()
        await router.setDirectoryListError(code: "method_not_found", message: "Unknown method")
        let store = try await makeRoutingConnectedStore(router: router)

        let result = await store.listTaskDirectories(macDeviceID: "test-mac", path: "~")

        #expect(result == .failure(.unsupported))
    }

    @Test(
        arguments: [
            ("directory_not_found", MobileTaskDirectoryListFailure.notFound),
            ("not_a_directory", MobileTaskDirectoryListFailure.notDirectory),
            ("permission_denied", MobileTaskDirectoryListFailure.permissionDenied),
            ("directory_unreadable", MobileTaskDirectoryListFailure.unreadable),
        ]
    )
    func mapsFilesystemErrors(
        code: String,
        expected: MobileTaskDirectoryListFailure
    ) async throws {
        let router = RoutingHostRouter()
        await router.setDirectoryListError(code: code, message: code)
        let store = try await makeRoutingConnectedStore(router: router)

        let result = await store.listTaskDirectories(macDeviceID: "test-mac", path: "~")

        #expect(result == .failure(expected))
    }

    @Test func rejectsRelativePathBeforeSendingRPC() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)

        let result = await store.listTaskDirectories(macDeviceID: "test-mac", path: "relative")

        #expect(result == .failure(.invalidPath))
        #expect(await router.recordedDirectoryListRequests().isEmpty)
    }
}

private extension Result {
    var successValue: Success? {
        guard case let .success(value) = self else { return nil }
        return value
    }
}
