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

    @Test func unauthorizedTailscaleRequestStaysAutomaticUntilCommitted() {
        let defaults = makeDefaults()
        let store = MobileConnectionMethodStore(defaults: defaults)

        #expect(store.request(.tailscale, hasAuthorizedTailscaleRoute: false))
        #expect(store.method == .automatic)
        #expect(store.presentedMethod == .tailscale)
        #expect(MobileConnectionMethodStore(defaults: defaults).method == .automatic)

        store.commitPendingTailscaleMethod()

        #expect(store.method == .tailscale)
        #expect(store.presentedMethod == .tailscale)
        #expect(MobileConnectionMethodStore(defaults: defaults).method == .tailscale)
    }

    @Test func cancellingPendingTailscaleKeepsLastUsableMethod() {
        let store = MobileConnectionMethodStore(defaults: makeDefaults())
        #expect(store.request(.tailscale, hasAuthorizedTailscaleRoute: false))

        store.cancelPendingMethod()

        #expect(store.pendingMethod == nil)
        #expect(store.presentedMethod == .automatic)
        #expect(store.method == .automatic)
    }

    @Test func authorizedTailscaleRequestCommitsImmediately() {
        let store = MobileConnectionMethodStore(defaults: makeDefaults())

        #expect(!store.request(.tailscale, hasAuthorizedTailscaleRoute: true))

        #expect(store.pendingMethod == nil)
        #expect(store.method == .tailscale)
    }
}
