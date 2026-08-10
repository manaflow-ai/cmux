import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileSimulatorStreamHintTests {
    @Test func dismissalPersistsAcrossStoreInstances() throws {
        let suiteName = "simulator-hint-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MobileSimulatorStreamHintDismissalStore(defaults: defaults)
        #expect(!store.isDismissed)
        store.markDismissed()
        #expect(store.isDismissed)
        #expect(MobileSimulatorStreamHintDismissalStore(defaults: defaults).isDismissed)
    }

    /// The composite mirrors the persisted flag observably and writes through
    /// on dismissal, so every mounted workspace view drops the banner at once
    /// and it stays gone on the next launch.
    @Test func compositeDismissalWritesThroughAndIsIdempotent() throws {
        let suiteName = "simulator-hint-composite-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MobileSimulatorStreamHintDismissalStore(defaults: defaults)

        let composite = MobileShellComposite(simulatorStreamHintDismissalStore: store)
        #expect(!composite.simulatorStreamHintDismissed)

        composite.dismissSimulatorStreamHint()
        #expect(composite.simulatorStreamHintDismissed)
        #expect(store.isDismissed)

        composite.dismissSimulatorStreamHint()
        #expect(composite.simulatorStreamHintDismissed)

        // A fresh composite over the same defaults starts dismissed.
        let relaunched = MobileShellComposite(simulatorStreamHintDismissalStore: store)
        #expect(relaunched.simulatorStreamHintDismissed)
    }
}
