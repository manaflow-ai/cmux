import Foundation
import Testing
@testable import CmuxBrowser

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
}
