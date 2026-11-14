import CmuxAuthRuntime
@testable import CmuxNextCloud
import Foundation
import Testing

/// A legacy default reads `<bundle id>.auth`; a NIGHTLY that signed in again while its build read the namespaced
/// store (4198271655001, before #36384) adopts that session once.
@MainActor @Suite struct CloudAuthNamespacedAdoptionTests {
    private func nightly(legacy: Bool, storageNamespace: String? = nil) -> CloudConfiguration {
        var configuration = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.nightly", bundled: [:], process: [:], isDebugBuild: false)
        if var selection = configuration.runtimeSelection {
            selection.authNamespace = "origin-0"
            selection.legacyStorage = legacy
            selection.authStorageNamespace = storageNamespace
            configuration = configuration.selecting(selection)
        }
        return configuration
    }

    @Test func aLegacyDefaultNamesTheNamespacedStoreItsUpdateUsed() throws {
        let home = URL(fileURLWithPath: "/Users/fixture")
        let previous = try #require(nightly(legacy: true).namespacedLegacyStorage(homeDirectory: home))
        #expect(nightly(legacy: true).keychainService == "com.cmuxterm.app.nightly.auth")
        #expect(previous.keychainService == "com.cmuxterm.app.nightly.auth.origin-0")
        // The store the update used is the one a selection scoped to `origin-0` names; the linked FFI says
        // where that folder is (classic's `cmux`, or `cmux-next` once the scoped stores move).
        let scoped = nightly(legacy: false).credentialsDirectory(homeDirectory: home)
        #expect(previous.credentialsDirectory == scoped)
        #expect(scoped.pathComponents.suffix(2) == ["com.cmuxterm.app.nightly", "origin-0"])
        #expect(CloudAuth.tokenStore(configuration: nightly(legacy: true), nightlySession: nil) is ImportingTokenStore)
    }

    @Test func anyOtherSelectionHasNoStoreToAdopt() {
        let home = URL(fileURLWithPath: "/Users/fixture")
        #expect(nightly(legacy: false).namespacedLegacyStorage(homeDirectory: home) == nil)
        #expect(nightly(legacy: true, storageNamespace: "project").namespacedLegacyStorage(homeDirectory: home) == nil)
        #expect(!(CloudAuth.tokenStore(configuration: nightly(legacy: false), nightlySession: nil) is ImportingTokenStore))
        #expect(CloudAuth.tokenStore(configuration: nightly(legacy: true), nightlySession: nil, memoryOnly: true) is MemoryStackTokenStore)
    }
}
