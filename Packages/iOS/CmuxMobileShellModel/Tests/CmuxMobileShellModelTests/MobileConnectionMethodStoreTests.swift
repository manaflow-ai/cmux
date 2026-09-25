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

    @Test func defaultsToIroh() {
        let store = MobileConnectionMethodStore(defaults: makeDefaults())
        #expect(store.method == .iroh)
    }

    @Test func persistsSelectionAcrossInstances() {
        let defaults = makeDefaults()
        let store = MobileConnectionMethodStore(defaults: defaults)
        store.method = .direct

        let reloaded = MobileConnectionMethodStore(defaults: defaults)
        #expect(reloaded.method == .direct)

        reloaded.method = .iroh
        #expect(MobileConnectionMethodStore(defaults: defaults).method == .iroh)
    }

    @Test func ignoresUnknownPersistedValue() {
        let defaults = makeDefaults()
        defaults.set("carrier-pigeon", forKey: MobileConnectionMethodStore.methodKey)

        let store = MobileConnectionMethodStore(defaults: defaults)
        #expect(store.method == .iroh)
    }

    /// Tailscale Only folded into Direct; an old stored choice is unknown now.
    @Test func legacyTailscaleOnlyValueFallsBackToIroh() {
        let defaults = makeDefaults()
        defaults.set("tailscale", forKey: MobileConnectionMethodStore.methodKey)

        #expect(MobileConnectionMethodStore(defaults: defaults).method == .iroh)
        #expect(MobileConnectionMethod.iroh.rawValue == "automatic")
    }

    @Test func recordsPreferenceChangesAtThePersistenceOwner() async {
        let log = DiagnosticLog(capacity: 4)
        let store = MobileConnectionMethodStore(
            defaults: makeDefaults(),
            diagnosticLog: log
        )

        store.method = .direct

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while await log.processedCount() < 2, clock.now < deadline {
            await Task.yield()
        }
        #expect(await log.processedCount() >= 2)
        let events = await log.snapshot().events
        #expect(events.first?.a
            == DiagnosticAppEventKind.connectionMethodConfigured.rawValue)
        #expect(events.first?.c == 0)
        let change = events.last
        #expect(change?.a
            == DiagnosticAppEventKind.connectionMethodPreferenceChanged.rawValue)
        #expect(change?.c == DiagnosticConnectionMethod.direct.rawValue)
    }

    /// A shared report window must state the configured method even when the
    /// bounded ring rolled past app launch, so the configured-method event is
    /// re-recordable on demand (the composition root calls it per foreground).
    @Test func recordsConfiguredMethodAtInitAndOnDemand() async {
        let defaults = makeDefaults()
        defaults.set(
            MobileConnectionMethod.direct.rawValue,
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
            #expect(event.c == DiagnosticConnectionMethod.direct.rawValue)
        }
    }
}
