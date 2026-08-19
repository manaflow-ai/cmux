import CMUXAuthCore
import Foundation
import Testing

@Suite("Backend environment override")
struct BackendEnvironmentOverrideTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "BackendEnvironmentOverrideTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("Absent key loads as production")
    func absentKeyLoadsAsProduction() {
        let defaults = makeDefaults()
        #expect(CMUXBackendEnvironmentOverride.load(from: defaults) == .production)
    }

    @Test("Staging round-trips through defaults")
    func stagingRoundTrips() {
        let defaults = makeDefaults()
        CMUXBackendEnvironmentOverride.staging.store(in: defaults)
        #expect(CMUXBackendEnvironmentOverride.load(from: defaults) == .staging)
    }

    @Test("Storing production removes the key")
    func storingProductionRemovesKey() {
        let defaults = makeDefaults()
        CMUXBackendEnvironmentOverride.staging.store(in: defaults)
        CMUXBackendEnvironmentOverride.production.store(in: defaults)
        #expect(defaults.string(forKey: CMUXBackendEnvironmentOverride.defaultsKey) == nil)
        #expect(CMUXBackendEnvironmentOverride.load(from: defaults) == .production)
    }

    @Test("Unknown raw value loads as production")
    func unknownRawValueLoadsAsProduction() {
        let defaults = makeDefaults()
        defaults.set("nightly", forKey: CMUXBackendEnvironmentOverride.defaultsKey)
        #expect(CMUXBackendEnvironmentOverride.load(from: defaults) == .production)
    }

    @Test("Staging maps to the development Stack environment")
    func stagingMapsToDevelopmentStack() {
        #expect(CMUXBackendEnvironmentOverride.staging.authEnvironment == .development)
        #expect(CMUXBackendEnvironmentOverride.production.authEnvironment == .production)
    }
}

@Suite("Backend environment switch gate")
struct BackendEnvironmentSwitchGateTests {
    private func user(email: String?, verified: Bool) -> CMUXAuthUser {
        CMUXAuthUser(
            id: "user-1",
            primaryEmail: email,
            displayName: nil,
            primaryEmailVerified: verified
        )
    }

    @Test("Verified manaflow email unlocks the picker")
    func verifiedManaflowEmailAllows() {
        #expect(CMUXBackendEnvironmentSwitchGate.allows(user(email: "aziz@manaflow.ai", verified: true)))
    }

    @Test("Domain match is case-insensitive")
    func domainMatchIsCaseInsensitive() {
        #expect(CMUXBackendEnvironmentSwitchGate.allows(user(email: "Lawrence@Manaflow.AI", verified: true)))
    }

    @Test("Unverified manaflow email is rejected")
    func unverifiedManaflowEmailRejected() {
        #expect(!CMUXBackendEnvironmentSwitchGate.allows(user(email: "aziz@manaflow.ai", verified: false)))
    }

    @Test("Other domains are rejected, including suffix look-alikes")
    func otherDomainsRejected() {
        #expect(!CMUXBackendEnvironmentSwitchGate.allows(user(email: "someone@example.com", verified: true)))
        #expect(!CMUXBackendEnvironmentSwitchGate.allows(user(email: "someone@notmanaflow.ai", verified: true)))
    }

    @Test("Missing email or user is rejected")
    func missingEmailOrUserRejected() {
        #expect(!CMUXBackendEnvironmentSwitchGate.allows(user(email: nil, verified: true)))
        #expect(!CMUXBackendEnvironmentSwitchGate.allows(nil))
    }
}

@Suite("CMUXAuthUser verified-email decoding")
struct CMUXAuthUserVerifiedDecodingTests {
    @Test("Legacy persisted JSON without the field decodes as unverified")
    func legacyJSONDecodesUnverified() throws {
        let legacy = Data(
            #"{"id":"user-1","primaryEmail":"aziz@manaflow.ai","displayName":"Aziz"}"#.utf8
        )
        let user = try JSONDecoder().decode(CMUXAuthUser.self, from: legacy)
        #expect(user.primaryEmailVerified == false)
        #expect(!CMUXBackendEnvironmentSwitchGate.allows(user))
    }

    @Test("Verified flag round-trips through Codable")
    func verifiedFlagRoundTrips() throws {
        let user = CMUXAuthUser(
            id: "user-1",
            primaryEmail: "aziz@manaflow.ai",
            displayName: "Aziz",
            primaryEmailVerified: true
        )
        let decoded = try JSONDecoder().decode(CMUXAuthUser.self, from: JSONEncoder().encode(user))
        #expect(decoded == user)
        #expect(decoded.primaryEmailVerified)
    }
}
