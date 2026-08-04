import Foundation
import Testing
@testable import CmuxMobileShellModel

@MainActor
@Suite struct MobileConnectionMethodStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "connection-method-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func defaultsToAutomatic() {
        let store = MobileConnectionMethodStore(defaults: makeDefaults())
        #expect(store.method == .automatic)
    }

    @Test func persistsSelectionAcrossInstances() {
        let defaults = makeDefaults()
        let store = MobileConnectionMethodStore(defaults: defaults)
        store.method = .tailscale

        let reloaded = MobileConnectionMethodStore(defaults: defaults)
        #expect(reloaded.method == .tailscale)

        reloaded.method = .automatic
        #expect(MobileConnectionMethodStore(defaults: defaults).method == .automatic)
    }

    @Test func ignoresUnknownPersistedValue() {
        let defaults = makeDefaults()
        defaults.set("carrier-pigeon", forKey: MobileConnectionMethodStore.methodKey)

        let store = MobileConnectionMethodStore(defaults: defaults)
        #expect(store.method == .automatic)
    }
}
