import Foundation
import Testing
@testable import CmuxMobileShellModel

@Suite struct MobileNotificationFeedIntroStoreTests {
    @Test func persistsDismissalInInjectedDefaults() throws {
        let suite = "MobileNotificationFeedIntroStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = MobileNotificationFeedIntroStore(defaults: defaults)
        #expect(!store.hasDismissedIntro)
        store.markDismissed()
        #expect(store.hasDismissedIntro)
    }
}
