import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite struct CmxIrohDebugRelayOverrideTests {
    @Test func parsesCanonicalHTTPSOriginAndAddsTrailingSlash() throws {
        let profile = try #require(
            CmxIrohDebugRelayOverride.profile(rawValue: " https://relay-test.example.com ")
        )
        #expect(profile.allowedRelayURLs == ["https://relay-test.example.com/"])
        #expect(profile.source == .custom)
        #expect(profile.activeRelays.map(\.url) == ["https://relay-test.example.com/"])
    }

    @Test func keepsExplicitPort() throws {
        let profile = try #require(
            CmxIrohDebugRelayOverride.profile(rawValue: "https://relay-test.example.com:8443/")
        )
        #expect(profile.allowedRelayURLs == ["https://relay-test.example.com:8443/"])
    }

    @Test(arguments: [
        nil,
        "",
        "   ",
        "http://insecure.example.com/",
        "https://relay.example.com/path",
        "https://relay.example.com/?q=1",
        "https://user:pw@relay.example.com/",
        "not a url",
    ] as [String?])
    func rejectsUnusableValues(_ raw: String?) {
        #expect(CmxIrohDebugRelayOverride.profile(rawValue: raw) == nil)
    }

    @Test func environmentWinsOverDefaults() throws {
        let suiteName = "cmux-debug-relay-override-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            "https://from-defaults.example.com/",
            forKey: CmxIrohDebugRelayOverride.key
        )
        #expect(
            CmxIrohDebugRelayOverride.rawValue(
                environment: [CmxIrohDebugRelayOverride.key: "https://from-env.example.com/"],
                defaults: defaults
            ) == "https://from-env.example.com/"
        )
        #expect(
            CmxIrohDebugRelayOverride.rawValue(
                environment: [:],
                defaults: defaults
            ) == "https://from-defaults.example.com/"
        )
    }

    @Test func hostResolutionPrefersOverride() throws {
        let fixture = try HostRuntimeFixture()
        let override = try #require(
            CmxIrohDebugRelayOverride.profile(rawValue: "https://relay-test.example.com/")
        )
        let resolved = try fixture.configuration.resolvedEndpointRelayProfile(
            now: Date(),
            debugOverride: override
        )
        #expect(resolved == override)

        let managed = try fixture.configuration.resolvedEndpointRelayProfile(
            now: Date(),
            debugOverride: nil
        )
        #expect(managed.source == .managed)
        #expect(managed.allowedRelayURLs == fixture.managedRelays)
    }

    @Test func clientResolutionPrefersOverride() throws {
        let fixture = try ClientRuntimeTestFixture()
        let override = try #require(
            CmxIrohDebugRelayOverride.profile(rawValue: "https://relay-test.example.com/")
        )
        let resolved = try fixture.configuration.resolvedEndpointRelayProfile(
            now: fixture.now,
            debugOverride: override
        )
        #expect(resolved == override)

        let managed = try fixture.configuration.resolvedEndpointRelayProfile(
            now: fixture.now,
            debugOverride: nil
        )
        #expect(managed.source == .managed)
        #expect(managed.allowedRelayURLs == Set(ClientRuntimeTestFixture.relayURLs))
    }
}
