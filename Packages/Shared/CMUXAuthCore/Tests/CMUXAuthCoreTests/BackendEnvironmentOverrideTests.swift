import CMUXAuthCore
import Foundation
import Testing

@Suite("Backend environment explicit choice (tri-state persistence)")
struct BackendEnvironmentOverrideTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "BackendEnvironmentOverrideTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("An absent key is no explicit choice (the build lane)")
    func absentKeyIsNoExplicitChoice() {
        let defaults = makeDefaults()
        #expect(CMUXBackendEnvironmentOverride.explicitChoice(from: defaults) == nil)
    }

    @Test("Staging round-trips through defaults")
    func stagingRoundTrips() {
        let defaults = makeDefaults()
        CMUXBackendEnvironmentOverride.staging.storeChoice(in: defaults)
        #expect(CMUXBackendEnvironmentOverride.explicitChoice(from: defaults) == .staging)
    }

    @Test("Storing production WRITES the key: explicit, not absent")
    func storingProductionWritesTheKey() {
        let defaults = makeDefaults()
        CMUXBackendEnvironmentOverride.staging.storeChoice(in: defaults)
        CMUXBackendEnvironmentOverride.production.storeChoice(in: defaults)
        #expect(
            defaults.string(forKey: CMUXBackendEnvironmentOverride.defaultsKey) == "production"
        )
        #expect(CMUXBackendEnvironmentOverride.explicitChoice(from: defaults) == .production)
    }

    @Test("clearChoice removes the key, returning to the build lane")
    func clearChoiceRemovesTheKey() {
        let defaults = makeDefaults()
        CMUXBackendEnvironmentOverride.staging.storeChoice(in: defaults)
        CMUXBackendEnvironmentOverride.clearChoice(in: defaults)
        #expect(defaults.string(forKey: CMUXBackendEnvironmentOverride.defaultsKey) == nil)
        #expect(CMUXBackendEnvironmentOverride.explicitChoice(from: defaults) == nil)
    }

    @Test("An unknown raw value is no explicit choice (fail-safe toward the bake)")
    func unknownRawValueIsNoExplicitChoice() {
        let defaults = makeDefaults()
        defaults.set("nightly", forKey: CMUXBackendEnvironmentOverride.defaultsKey)
        #expect(CMUXBackendEnvironmentOverride.explicitChoice(from: defaults) == nil)
    }

    @Test("Staging maps to the development Stack environment")
    func stagingMapsToDevelopmentStack() {
        #expect(CMUXBackendEnvironmentOverride.staging.authEnvironment == .development)
        #expect(CMUXBackendEnvironmentOverride.production.authEnvironment == .production)
    }
}

@Suite("Backend environment selection model")
struct BackendEnvironmentSelectionTests {
    @Test("Selections resolve their environment")
    func selectionsResolveTheirEnvironment() {
        #expect(
            CMUXBackendEnvironmentSelection.lane(resolves: .staging).resolvedEnvironment == .staging
        )
        #expect(
            CMUXBackendEnvironmentSelection.lane(resolves: .production).resolvedEnvironment
                == .production
        )
        #expect(
            CMUXBackendEnvironmentSelection.explicit(.staging).resolvedEnvironment == .staging
        )
        #expect(
            CMUXBackendEnvironmentSelection.explicit(.production).resolvedEnvironment
                == .production
        )
    }

    @Test("isExplicit distinguishes a persisted choice from the lane")
    func isExplicitDistinguishesChoiceFromLane() {
        #expect(CMUXBackendEnvironmentSelection.explicit(.production).isExplicit)
        #expect(CMUXBackendEnvironmentSelection.explicit(.staging).isExplicit)
        #expect(!CMUXBackendEnvironmentSelection.lane(resolves: .production).isExplicit)
        #expect(!CMUXBackendEnvironmentSelection.lane(resolves: .staging).isExplicit)
    }

    @Test("PIN: ONLY explicit staging gates — the lane and explicit production never do")
    func onlyExplicitStagingGates() {
        #expect(CMUXBackendEnvironmentSelection.explicit(.staging).requiresGatedSession)
        #expect(!CMUXBackendEnvironmentSelection.explicit(.production).requiresGatedSession)
        // A staging LANE never gates: dev rigs baked to staging keep plain
        // sign-in/sign-out, and the transaction's revert-to-lane can't loop.
        #expect(!CMUXBackendEnvironmentSelection.lane(resolves: .staging).requiresGatedSession)
        #expect(!CMUXBackendEnvironmentSelection.lane(resolves: .production).requiresGatedSession)
    }

    @Test("Selection identity: a lane and an explicit choice resolving the same environment differ")
    func laneAndExplicitAreDistinctIdentities() {
        #expect(
            CMUXBackendEnvironmentSelection.lane(resolves: .staging)
                != CMUXBackendEnvironmentSelection.explicit(.staging)
        )
        #expect(
            CMUXBackendEnvironmentSelection.lane(resolves: .production)
                != CMUXBackendEnvironmentSelection.explicit(.production)
        )
    }

    @Test("Build lanes resolve staging only for the staging lane")
    func buildLanesResolve() {
        #expect(CMUXBackendEnvironmentBuildLane.production.resolvedEnvironment == .production)
        #expect(CMUXBackendEnvironmentBuildLane.staging.resolvedEnvironment == .staging)
        #expect(
            CMUXBackendEnvironmentBuildLane.custom(label: "localhost:4123").resolvedEnvironment
                == .production
        )
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
