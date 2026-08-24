import Foundation
import Testing
@testable import CmuxAuthRuntime

// Filters-sync coverage for `PushRegistrationService.updateFilters(_:)`.
// Declared as an extension of the `.serialized` PushRegistrationServiceTests
// suite because these tests share the process-wide
// `PushRegistrationURLProtocol.script` with the lifecycle tests.
extension PushRegistrationServiceTests {
    private func makeFiltersService(
        suite: String = "push-filters-\(UUID().uuidString)"
    ) -> PushRegistrationService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PushRegistrationURLProtocol.self]
        return PushRegistrationService(
            tokenProvider: FakeTokenProvider(),
            apiBaseURL: "https://example.test",
            bundleID: "dev.cmux.ios.filters",
            apnsEnvironment: "sandbox",
            suiteName: suite,
            pendingUnregisterStoreURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("push-cleanup-\(suite).sqlite3"),
            session: URLSession(configuration: configuration),
            retryDelays: []
        )
    }

    private var filtersDocumentFixture: Data {
        Data(#"{"version":1,"rules":[{"id":"11111111-2222-3333-4444-555555555555","enabled":true,"titlePattern":"fail"}]}"#.utf8)
    }

    private func filtersBody(_ data: Data?) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: #require(data))
                as? [String: Any]
        )
    }

    @Test func updateFiltersPutsTheDocumentVerbatim() async throws {
        let script = PushRegistrationURLProtocol.script
        await script.reset([
            .response(200), // POST /api/device-tokens
            .response(200), // PUT /api/device-tokens/filters
        ])
        let service = makeFiltersService()
        await service.setEnabled(true)
        await service.register(deviceToken: Data([0x0a, 0x0b]))
        await service.updateFilters(filtersDocumentFixture)

        #expect(await script.waitForRequestCount(2))
        let requests = await script.requests
        #expect(requests.count == 2)
        let put = try #require(requests.last)
        #expect(put.httpMethod == "PUT")
        #expect(put.url?.path == "/api/device-tokens/filters")
        #expect(put.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(put.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == "refresh")

        let bodies = await script.requestBodies
        let body = try filtersBody(bodies.last.flatMap { $0 })
        #expect(body["deviceToken"] as? String == "0a0b")
        #expect(body["bundleId"] as? String == "dev.cmux.ios.filters")
        let filters = try #require(body["filters"] as? [String: Any])
        #expect(filters["version"] as? Int == 1)
        let rules = try #require(filters["rules"] as? [[String: Any]])
        #expect(rules.first?["titlePattern"] as? String == "fail")
    }

    @Test func updateFiltersBeforeAnyTokenDefersUntilRegistration() async throws {
        let script = PushRegistrationURLProtocol.script
        await script.reset([
            .response(200), // POST /api/device-tokens
            .response(200), // PUT /api/device-tokens/filters (deferred re-push)
        ])
        let service = makeFiltersService()
        await service.setEnabled(true)
        await service.updateFilters(filtersDocumentFixture)
        #expect(await script.requests.isEmpty)

        await service.register(deviceToken: Data([0x01]))
        #expect(await script.waitForRequestCount(2))
        let methods = await script.requests.map { $0.httpMethod ?? "?" }
        #expect(methods == ["POST", "PUT"])
    }

    @Test func successfulReRegistrationRePushesTheRetainedFilters() async throws {
        let script = PushRegistrationURLProtocol.script
        await script.reset([
            .response(200), // POST initial registration
            .response(200), // PUT filters
            .response(200), // POST re-registration (sync)
            .response(200), // PUT filters re-push
        ])
        let service = makeFiltersService()
        await service.setEnabled(true)
        await service.register(deviceToken: Data([0x02]))
        await service.updateFilters(filtersDocumentFixture)
        await service.syncTokenIfPossible()

        #expect(await script.waitForRequestCount(4))
        let methods = await script.requests.map { $0.httpMethod ?? "?" }
        #expect(methods == ["POST", "PUT", "POST", "PUT"])
    }

    @Test func unknownDeviceTokenReRegistersOnceThenRetriesThePutOnce() async throws {
        let script = PushRegistrationURLProtocol.script
        await script.reset([
            .response(200), // POST initial registration
            .response(404, json: #"{"error":"unknown_device_token"}"#), // PUT
            .response(200), // POST recovery re-registration
            .response(200), // PUT retry
        ])
        let service = makeFiltersService()
        await service.setEnabled(true)
        await service.register(deviceToken: Data([0x03]))
        await service.updateFilters(filtersDocumentFixture)

        #expect(await script.waitForRequestCount(4))
        let methods = await script.requests.map { $0.httpMethod ?? "?" }
        #expect(methods == ["POST", "PUT", "POST", "PUT"])
        // The retry is bounded: no fifth request follows.
        #expect(await script.requests.count == 4)
    }

    @Test func clearingFiltersPutsAnExplicitNull() async throws {
        let script = PushRegistrationURLProtocol.script
        await script.reset([
            .response(200), // POST registration
            .response(200), // PUT document
            .response(200), // PUT null
        ])
        let service = makeFiltersService()
        await service.setEnabled(true)
        await service.register(deviceToken: Data([0x04]))
        await service.updateFilters(filtersDocumentFixture)
        await service.updateFilters(nil)

        #expect(await script.waitForRequestCount(3))
        let bodies = await script.requestBodies
        let body = try filtersBody(bodies.last.flatMap { $0 })
        #expect(body["filters"] is NSNull)
    }
}
