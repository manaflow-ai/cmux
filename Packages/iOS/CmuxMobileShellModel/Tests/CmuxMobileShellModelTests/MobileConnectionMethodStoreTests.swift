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

    @Test func defaultsToTailscale() {
        let store = MobileConnectionMethodStore(defaults: makeDefaults())
        #expect(store.method == .tailscale)
    }

    @Test func persistsSelectionAcrossInstances() {
        let defaults = makeDefaults()
        let store = MobileConnectionMethodStore(defaults: defaults)
        store.method = .tailscale

        let reloaded = MobileConnectionMethodStore(defaults: defaults)
        #expect(reloaded.method == .tailscale)
    }

    /// Retired persisted choices from older builds ("automatic", "iroh",
    /// "direct") and unknown values all read as Tailscale, so a stored
    /// preference never crashes or drops an existing pairing.
    @Test(arguments: ["automatic", "iroh", "direct", "carrier-pigeon"])
    func retiredPersistedValuesReadAsTailscale(rawValue: String) {
        let defaults = makeDefaults()
        defaults.set(rawValue, forKey: MobileConnectionMethodStore.methodKey)

        let store = MobileConnectionMethodStore(defaults: defaults)
        #expect(store.method == .tailscale)
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
            #expect(event.c == 1)
        }
    }
}
