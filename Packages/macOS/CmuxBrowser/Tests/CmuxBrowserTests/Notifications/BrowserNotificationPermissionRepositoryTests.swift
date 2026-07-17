import Foundation
import Testing
@testable import CmuxBrowser

@MainActor
@Suite
struct BrowserNotificationPermissionRepositoryTests {
    @Test func decisionsAreProfileScopedAndPersisted() throws {
        let suite = "cmux.notification-permissions.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let work = UUID()
        let personal = UUID()
        let origin = try #require(URL(string: "HTTPS://Example.COM:8443/inbox?q=1"))
        let repository = BrowserNotificationPermissionRepository(defaults: defaults)

        #expect(repository.decision(for: origin, profileID: work) == .prompt)
        repository.setDecision(.allowed, for: origin, profileID: work)
        repository.setDecision(.denied, for: origin, profileID: personal)

        let reloaded = BrowserNotificationPermissionRepository(defaults: defaults)
        #expect(reloaded.decision(for: origin, profileID: work) == .allowed)
        #expect(reloaded.decision(for: origin, profileID: personal) == .denied)
        #expect(reloaded.allowedOrigins(for: work) == ["https://example.com:8443"])
        #expect(reloaded.deniedOrigins(for: personal) == ["https://example.com:8443"])
    }

    @Test func clearRemovesOnlyOneProfileAndRejectsUnsafeOrigins() throws {
        let suite = "cmux.notification-permissions.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = UUID()
        let second = UUID()
        let origin = try #require(URL(string: "https://example.com/path"))
        let fileURL = try #require(URL(string: "file:///tmp/example"))
        let repository = BrowserNotificationPermissionRepository(defaults: defaults)
        repository.setDecision(.allowed, for: origin, profileID: first)
        repository.setDecision(.allowed, for: origin, profileID: second)

        repository.clear(profileID: first)

        #expect(repository.decision(for: origin, profileID: first) == .prompt)
        #expect(repository.decision(for: origin, profileID: second) == .allowed)
        #expect(repository.decision(for: fileURL, profileID: first) == .denied)
    }

    @Test func legacyDisplayOriginMigrationIsAtomicAndProfileScoped() throws {
        let suite = "cmux.notification-permissions.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let migratingProfile = UUID()
        let otherProfile = UUID()
        let legacyDisplayOrigin = try #require(URL(string: "http://localhost:3000"))
        let securityOrigin = try #require(URL(string: "http://cmux-loopback.localtest.me:3000"))
        let unrelatedOrigin = try #require(URL(string: "https://example.com"))
        let repository = BrowserNotificationPermissionRepository(defaults: defaults)
        repository.setDecision(.allowed, for: legacyDisplayOrigin, profileID: migratingProfile)
        repository.setDecision(.denied, for: unrelatedOrigin, profileID: migratingProfile)
        repository.setDecision(.denied, for: legacyDisplayOrigin, profileID: otherProfile)

        #expect(repository.migrateDecisionIfNeeded(
            from: legacyDisplayOrigin,
            to: securityOrigin,
            profileID: migratingProfile
        ) == .allowed)
        #expect(repository.decision(for: securityOrigin, profileID: migratingProfile) == .allowed)
        #expect(repository.decision(for: legacyDisplayOrigin, profileID: migratingProfile) == .prompt)
        #expect(repository.decision(for: unrelatedOrigin, profileID: migratingProfile) == .denied)
        #expect(repository.decision(for: legacyDisplayOrigin, profileID: otherProfile) == .denied)
    }

    @Test func canonicalOriginPreservesIPv6LiteralHosts() throws {
        let loopback = try #require(URL(string: "http://[::1]:8080/inbox?q=1"))
        let expanded = try #require(URL(string: "https://[2001:db8::7]:9443/path"))

        #expect(BrowserNotificationPermissionRepository.canonicalOrigin(loopback) == "http://[::1]:8080")
        #expect(BrowserNotificationPermissionRepository.canonicalOrigin(expanded) == "https://[2001:db8::7]:9443")
    }

    @Test func liveRepositoryInstancesObserveEachOthersPersistedMutations() throws {
        let suite = "cmux.notification-permissions.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let profileID = UUID()
        let firstOrigin = try #require(URL(string: "https://first.example"))
        let secondOrigin = try #require(URL(string: "https://second.example"))
        let first = BrowserNotificationPermissionRepository(defaults: defaults)
        let second = BrowserNotificationPermissionRepository(defaults: defaults)

        first.setDecision(.allowed, for: firstOrigin, profileID: profileID)
        #expect(second.decision(for: firstOrigin, profileID: profileID) == .allowed)

        second.setDecision(.denied, for: secondOrigin, profileID: profileID)
        #expect(first.decision(for: secondOrigin, profileID: profileID) == .denied)
        #expect(first.allowedOrigins(for: profileID) == ["https://first.example"])
        #expect(first.deniedOrigins(for: profileID) == ["https://second.example"])

        second.clear(profileID: profileID)
        #expect(first.origins(for: profileID).allowed.isEmpty)
        #expect(first.origins(for: profileID).denied.isEmpty)
    }
}
