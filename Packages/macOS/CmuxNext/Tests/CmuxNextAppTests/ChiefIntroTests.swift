import Foundation
@testable import CmuxNextHome
import Testing

/// The Chief's first-open intro shows once per install, never again after it was shown.
@Suite(.serialized) struct ChiefIntroTests {
    /// A defaults suite of its own, so the test never reads or writes the person's settings.
    static func isolatedDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "cmux-chief-intro-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite) ?? .standard, suite)
    }

    @Test func aFreshInstallShowsTheIntroThenNever() {
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChiefIntroStore(defaults: defaults)
        #expect(store.shouldShow)
        store.markShown()
        #expect(!store.shouldShow)
    }

    @Test func theShownFlagSurvivesARelaunch() {
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        ChiefIntroStore(defaults: defaults).markShown()
        // A new store over the same defaults is the next launch of cmux.
        #expect(!ChiefIntroStore(defaults: defaults).shouldShow)
    }
}
