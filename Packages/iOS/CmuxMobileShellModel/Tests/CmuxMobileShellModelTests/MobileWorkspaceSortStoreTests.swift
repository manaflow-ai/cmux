import Foundation
import Testing

@testable import CmuxMobileShellModel

/// Behavior tests for ``MobileWorkspaceSortStore`` using a suite-scoped
/// `UserDefaults` so they never touch `UserDefaults.standard`.
@Suite struct MobileWorkspaceSortStoreTests {
    private func makeDefaults() -> (defaults: UserDefaults, open: @Sendable () -> UserDefaults) {
        makeTestDefaultsSuite("MobileWorkspaceSortStoreTests")
    }

    @Test func freshStoreDefaultsToAutomaticWithNoPriority() {
        let store = MobileWorkspaceSortStore(defaults: makeDefaults().open)
        #expect(store.mode == .automatic)
        #expect(store.computerPriority.isEmpty)
    }

    @Test func modeAndPriorityPersistAcrossInstances() {
        let (_, open) = makeDefaults()
        var store = MobileWorkspaceSortStore(defaults: open)
        store.setMode(.computerPriority)
        store.setComputerPriority(["mac-b", "mac-a"])

        let reloaded = MobileWorkspaceSortStore(defaults: open)
        #expect(reloaded.mode == .computerPriority)
        #expect(reloaded.computerPriority == ["mac-b", "mac-a"])
    }

    @Test func corruptPayloadReadsAsDefaults() {
        let (defaults, open) = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: MobileWorkspaceSortStore.defaultsKey)
        let store = MobileWorkspaceSortStore(defaults: open)
        #expect(store.mode == .automatic)
        #expect(store.computerPriority.isEmpty)
    }

    @Test func unknownFutureModeReadsAsAutomaticWithoutRewriting() throws {
        let (defaults, open) = makeDefaults()
        let payload = Data(#"{"mode":"holographic","computerPriority":["mac-a"]}"#.utf8)
        defaults.set(payload, forKey: MobileWorkspaceSortStore.defaultsKey)

        var store = MobileWorkspaceSortStore(defaults: open)
        #expect(store.mode == .automatic)
        #expect(store.computerPriority == ["mac-a"])

        // A same-value write must not clobber the newer build's stored mode.
        store.setComputerPriority(["mac-a"])
        let kept = try #require(defaults.data(forKey: MobileWorkspaceSortStore.defaultsKey))
        #expect(String(decoding: kept, as: UTF8.self).contains("holographic"))
    }

    @Test func settingModePreservesPriorityAndViceVersa() {
        let (_, open) = makeDefaults()
        var store = MobileWorkspaceSortStore(defaults: open)
        store.setComputerPriority(["mac-a"])
        store.setMode(.recentActivity)

        let reloaded = MobileWorkspaceSortStore(defaults: open)
        #expect(reloaded.mode == .recentActivity)
        #expect(reloaded.computerPriority == ["mac-a"])
    }

    @Test func legacyPriorityMigrationRunsOnlyOnce() {
        let (defaults, open) = makeDefaults()
        defaults.set(
            Data(#"{"mode":"computerPriority","computerPriority":["mac-a"]}"#.utf8),
            forKey: MobileWorkspaceSortStore.defaultsKey
        )
        var store = MobileWorkspaceSortStore(defaults: open)
        #expect(store.needsComputerIdentityMigration)

        store.migrateLegacyComputerPriority(["mac-a\u{1F}stable"])
        #expect(!store.needsComputerIdentityMigration)
        store.migrateLegacyComputerPriority(["mac-a\u{1F}nightly"])

        let reloaded = MobileWorkspaceSortStore(defaults: open)
        #expect(reloaded.computerPriority == ["mac-a\u{1F}stable"])
        #expect(!reloaded.needsComputerIdentityMigration)
    }
}
