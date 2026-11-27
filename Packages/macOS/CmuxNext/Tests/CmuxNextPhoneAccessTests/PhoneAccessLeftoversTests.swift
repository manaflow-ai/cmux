import CmuxNextPhoneAccess
import Foundation
import Testing

/// #42780 removed the iroh phone listener (Settings > Accounts > Phone Access). Its one-time
/// `PhoneAccessMigration` left `cmux.phoneAccess.migrated.v1` in this app's defaults on every Mac
/// that launched it. The launch cleanup removes that flag, and only that flag, off the main thread.
@Suite struct PhoneAccessLeftoversTests {
    private static func withSuite(_ body: (String, UserDefaults) async throws -> Void) async throws {
        let name = "cmux.tests.PhoneAccessLeftovers.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(name, defaults)
    }

    @Test func removesTheRetiredMigrationFlagAndNothingElse() async throws {
        try await Self.withSuite { name, defaults in
            defaults.set(true, forKey: "cmux.phoneAccess.migrated.v1")
            defaults.set(true, forKey: "cmux.phoneAccess.other")
            defaults.set("kept", forKey: "mobile.allowIPhoneConnections")
            let removed = await PhoneAccessLeftovers(suiteName: name).cleanUpInBackground().value
            #expect(removed == ["cmux.phoneAccess.migrated.v1"])
            #expect(defaults.object(forKey: "cmux.phoneAccess.migrated.v1") == nil)
            #expect(defaults.bool(forKey: "cmux.phoneAccess.other"))
            #expect(defaults.string(forKey: "mobile.allowIPhoneConnections") == "kept")
        }
    }

    @Test func isIdempotent() async throws {
        try await Self.withSuite { name, defaults in
            defaults.set(false, forKey: "cmux.phoneAccess.migrated.v1")
            let leftovers = PhoneAccessLeftovers(suiteName: name)
            #expect(await leftovers.cleanUpInBackground().value == ["cmux.phoneAccess.migrated.v1"])
            #expect(await leftovers.cleanUpInBackground().value.isEmpty)
            #expect(defaults.dictionaryRepresentation()["cmux.phoneAccess.migrated.v1"] == nil)
        }
    }
}
