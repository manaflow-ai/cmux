import Foundation
import Testing

@testable import CmuxMobileShellModel

/// Behavior tests for ``MobileNotificationPreferences`` using a suite-scoped
/// `UserDefaults` so they never touch `UserDefaults.standard`.
@Suite struct MobileNotificationPreferencesTests {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "MobileNotificationPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func unsetPreferencesDefaultToAlwaysForwardingWhileDisabled() throws {
        let defaults = try makeDefaults()
        let preferences = MobileNotificationPreferences(defaults: defaults)

        #expect(!preferences.isEnabled)
        #expect(!preferences.isForwardingEnabled)
        #expect(!preferences.receivesNotifications)
        #expect(preferences.forwardingMode == .always)
        #expect(!preferences.hidesContent)
    }

    @Test func invalidStoredModeFallsBackToAlways() throws {
        let defaults = try makeDefaults()
        defaults.set("sometimes", forKey: MobileNotificationPreferences.forwardingModeKey)

        #expect(MobileNotificationPreferences(defaults: defaults).forwardingMode == .always)
    }

    @Test func missingForwardingMirrorDefaultsFromLegacyLocalOptIn() throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: MobileNotificationPreferences.enabledKey)

        let preferences = MobileNotificationPreferences(defaults: defaults)

        #expect(preferences.isEnabled)
        #expect(preferences.isForwardingEnabled)
        #expect(preferences.receivesNotifications)
    }

    @Test func persistsAndReadsNotificationPreferences() throws {
        let defaults = try makeDefaults()
        let preferences = MobileNotificationPreferences(
            isEnabled: true,
            forwardingMode: .onlyWhenAway,
            hidesContent: true
        )

        preferences.persist(to: defaults)

        #expect(MobileNotificationPreferences(defaults: defaults) == preferences)
    }
}
