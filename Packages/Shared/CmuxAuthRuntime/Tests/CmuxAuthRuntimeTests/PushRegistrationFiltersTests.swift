import Foundation
import Testing
@testable import CmuxAuthRuntime

// Filters-sync coverage for `PushRegistrationService.updateFilters(_:)`.
// Declared as an extension of the `.serialized` PushRegistrationServiceTests
// suite because these tests share the process-wide
// `PushRegistrationURLProtocol.script` with the lifecycle tests.
extension PushRegistrationServiceTests {
    private func makeFiltersService(
        tokenProvider: any TokenProviding = FakeTokenProvider(),
        suite: String = "push-filters-\(UUID().uuidString)"
    ) -> PushRegistrationService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PushRegistrationURLProtocol.self]
        return PushRegistrationService(
            tokenProvider: tokenProvider,
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
        let data = try #require(data)
        return try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
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

    @Test func foreignAccountDocumentIsDroppedInsteadOfFollowingReRegistration() async throws {
        let script = PushRegistrationURLProtocol.script
        await script.reset([
            .response(200), // POST registration under account A
            .response(200), // PUT filters authored by account A
            .response(200), // POST re-registration under account B
        ])
        let provider = MutablePushTokenProvider(
            accountID: "account-a",
            accessToken: "a-access",
            refreshToken: "a-refresh"
        )
        let suite = "push-filters-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let service = makeFiltersService(tokenProvider: provider, suite: suite)
        await service.setEnabled(true)
        await service.register(deviceToken: Data([0x05]))
        await service.updateFilters(filtersDocumentFixture)
        #expect(await script.waitForRequestCount(2))

        await provider.switchSession(
            accountID: "account-b",
            accessToken: "b-access",
            refreshToken: "b-refresh"
        )
        await service.syncTokenIfPossible()

        // Account A's rules must not mute account B: the retained document is
        // dropped, not re-pushed, so no PUT follows B's registration.
        let putFollowedReRegistration = await script.waitForRequestCount(
            4,
            timeout: .milliseconds(50)
        )
        #expect(!putFollowedReRegistration)
        let methods = await script.requests.map { $0.httpMethod ?? "?" }
        #expect(methods == ["POST", "PUT", "POST"])
        #expect(
            defaults.data(
                forKey: "cmux.notifications.pushFilters.document.v1"
            ) == nil
        )
        #expect(
            defaults.string(
                forKey: "cmux.notifications.pushFilters.accountID.v1"
            ) == nil
        )
    }

    @Test func undecodableRetainedDocumentDoesNotClearServerFilters() async throws {
        let script = PushRegistrationURLProtocol.script
        await script.reset([
            .response(200), // POST registration
            .response(200), // PUT for the corrected document
        ])
        let service = makeFiltersService()
        await service.setEnabled(true)
        await service.register(deviceToken: Data([0x06]))
        await service.updateFilters(Data("not-json".utf8))

        // Fail closed: the undecodable document must not become a `null`
        // PUT, which would clear the server-side filters and unmute
        // everything. `updateFilters` awaited its drain, so any wrongly
        // issued PUT would already be captured.
        #expect(await script.requests.map { $0.httpMethod ?? "?" } == ["POST"])

        // Nothing was acknowledged: a later corrected document supersedes the
        // undecodable one and is the first PUT the server sees.
        await service.updateFilters(filtersDocumentFixture)
        #expect(await script.waitForRequestCount(2))
        let methods = await script.requests.map { $0.httpMethod ?? "?" }
        #expect(methods == ["POST", "PUT"])
        let bodies = await script.requestBodies
        let body = try filtersBody(bodies.last.flatMap { $0 })
        let filters = try #require(body["filters"] as? [String: Any])
        #expect(filters["version"] as? Int == 1)
    }

    @Test func syncTokenIfPossibleRedrivesAnUnacknowledgedPersistedDocument() async throws {
        let script = PushRegistrationURLProtocol.script
        await script.reset([
            .response(503), // POST fails: no post-registration re-push path
            .response(200), // PUT re-driven from syncTokenIfPossible
        ])
        // A relaunch after the document was persisted but before its PUT
        // completed: registration state is cached in defaults while the
        // acknowledgement, which is in-memory only, is lost.
        let suite = "push-filters-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")
        defaults.set("0a", forKey: "cmux.notifications.deviceTokenHex")
        defaults.set(
            "push-user-1",
            forKey: "cmux.notifications.registeredAccountID"
        )
        defaults.set(
            filtersDocumentFixture,
            forKey: "cmux.notifications.pushFilters.document.v1"
        )
        defaults.set(
            "push-user-1",
            forKey: "cmux.notifications.pushFilters.accountID.v1"
        )
        let service = makeFiltersService(suite: suite)

        await service.syncTokenIfPossible()

        #expect(await script.waitForRequestCount(2))
        let methods = await script.requests.map { $0.httpMethod ?? "?" }
        #expect(methods == ["POST", "PUT"])
        let bodies = await script.requestBodies
        let body = try filtersBody(bodies.last.flatMap { $0 })
        #expect(body["deviceToken"] as? String == "0a")
        let filters = try #require(body["filters"] as? [String: Any])
        #expect(filters["version"] as? Int == 1)
    }
}
