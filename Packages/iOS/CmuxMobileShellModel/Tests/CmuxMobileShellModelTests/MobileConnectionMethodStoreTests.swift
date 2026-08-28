import Foundation
import CMUXMobileCore
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

    @Test func defaultsToRelay() {
        let store = MobileConnectionMethodStore(defaults: makeDefaults())
        #expect(store.method == .relay)
    }

    @Test func legacyAutomaticAndDirectValuesMigrateToRelay() {
        for legacy in ["automatic", "direct"] {
            let defaults = makeDefaults()
            defaults.set(legacy, forKey: MobileConnectionMethodStore.methodKey)
            #expect(MobileConnectionMethodStore(defaults: defaults).method == .relay)
        }
    }

    @Test func persistsSelectionAcrossInstances() {
        let defaults = makeDefaults()
        let store = MobileConnectionMethodStore(defaults: defaults)
        store.method = .tailscale

        let reloaded = MobileConnectionMethodStore(defaults: defaults)
        #expect(reloaded.method == .tailscale)

        reloaded.method = .relay
        #expect(MobileConnectionMethodStore(defaults: defaults).method == .relay)
    }

    @Test func ignoresUnknownPersistedValue() {
        let defaults = makeDefaults()
        defaults.set("carrier-pigeon", forKey: MobileConnectionMethodStore.methodKey)

        let store = MobileConnectionMethodStore(defaults: defaults)
        #expect(store.method == .relay)
    }

    @Test func recordsPreferenceChangesAtThePersistenceOwner() async {
        let log = DiagnosticLog(capacity: 4)
        let store = MobileConnectionMethodStore(
            defaults: makeDefaults(),
            diagnosticLog: log
        )

        store.method = .tailscale

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while await log.processedCount() < 2, clock.now < deadline {
            await Task.yield()
        }
        #expect(await log.processedCount() >= 2)
        let events = await log.snapshot().events
        #expect(events.first?.a
            == DiagnosticAppEventKind.connectionMethodConfigured.rawValue)
        #expect(events.first?.c == DiagnosticConnectionMethod.relay.rawValue)
        let change = events.last
        #expect(change?.a
            == DiagnosticAppEventKind.connectionMethodPreferenceChanged.rawValue)
        #expect(change?.c == DiagnosticConnectionMethod.tailscale.rawValue)
    }

    /// A shared report window must state the configured method even when the
    /// bounded ring rolled past app launch, so the configured-method event is
    /// re-recordable on demand (the composition root calls it per foreground).
    @Test func recordsConfiguredMethodAtInitAndOnDemand() async {
        let defaults = makeDefaults()
        defaults.set(
            MobileConnectionMethod.tailscale.rawValue,
            forKey: MobileConnectionMethodStore.methodKey
        )
        let log = DiagnosticLog(capacity: 4)
        let store = MobileConnectionMethodStore(
            defaults: defaults,
            diagnosticLog: log
        )

        store.recordConfiguredMethodDiagnostic()

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while await log.processedCount() < 2, clock.now < deadline {
            await Task.yield()
        }
        let events = await log.snapshot().events
        #expect(events.count == 2)
        for event in events {
            #expect(event.a
                == DiagnosticAppEventKind.connectionMethodConfigured.rawValue)
            #expect(event.c == DiagnosticConnectionMethod.tailscale.rawValue)
        }
    }
}
