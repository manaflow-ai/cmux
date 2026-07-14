import Foundation
import Testing
@testable import CmuxSettings

@Suite("UsageTipsStore")
struct UsageTipsStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "UsageTipsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func defaultsToEnabledAndCanBeDisabled() {
        let defaults = makeDefaults()
        let store = UsageTipsStore(defaults: defaults)

        #expect(store.isEnabled)
        store.setEnabled(false)
        #expect(!UsageTipsStore(defaults: defaults).isEnabled)
    }

    @Test func seenIdentifiersPersistWithoutDuplicates() {
        let defaults = makeDefaults()
        let store = UsageTipsStore(defaults: defaults)

        store.markSeen("global-search")
        store.markSeen("canvas-layout")
        store.markSeen("global-search")

        #expect(UsageTipsStore(defaults: defaults).seenTipIDs == Set([
            "canvas-layout",
            "global-search",
        ]))
    }

    @Test func welcomeEligibilityUsesTheCatalogKey() {
        let defaults = makeDefaults()
        let store = UsageTipsStore(defaults: defaults)

        #expect(!store.hasShownWelcome)
        AccountCatalogSection().welcomeShown.set(true, in: defaults)
        #expect(store.hasShownWelcome)
    }
}
