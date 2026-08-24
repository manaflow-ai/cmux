import CMUXAuthCore
import Foundation
import Testing

@Suite("Backend environment switch rebuild marker")
struct BackendEnvironmentSwitchRebuildMarkerTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "BackendEnvironmentSwitchRebuildMarkerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("Armed marker is consumed exactly once")
    func armedMarkerConsumesOnce() {
        let defaults = makeDefaults()
        CMUXBackendEnvironmentSwitchRebuildMarker.arm(in: defaults)
        #expect(CMUXBackendEnvironmentSwitchRebuildMarker.consume(from: defaults))
        // The second consumer (an organic flip after a crash-recovered
        // switch) must see today's clear semantics.
        #expect(!CMUXBackendEnvironmentSwitchRebuildMarker.consume(from: defaults))
        #expect(defaults.object(
            forKey: CMUXBackendEnvironmentSwitchRebuildMarker.defaultsKey
        ) == nil)
    }

    @Test("Unarmed marker consumes false")
    func unarmedMarkerConsumesFalse() {
        let defaults = makeDefaults()
        #expect(!CMUXBackendEnvironmentSwitchRebuildMarker.consume(from: defaults))
    }

    @Test("Re-arming after consumption suppresses one more pass")
    func reArmingSuppressesOneMorePass() {
        let defaults = makeDefaults()
        CMUXBackendEnvironmentSwitchRebuildMarker.arm(in: defaults)
        #expect(CMUXBackendEnvironmentSwitchRebuildMarker.consume(from: defaults))
        CMUXBackendEnvironmentSwitchRebuildMarker.arm(in: defaults)
        #expect(CMUXBackendEnvironmentSwitchRebuildMarker.consume(from: defaults))
        #expect(!CMUXBackendEnvironmentSwitchRebuildMarker.consume(from: defaults))
    }
}

@Suite("Backend environment gated-session flag")
struct BackendEnvironmentGatedSessionTests {
    @Test("Only staging requires a gated session; production never gates")
    func onlyStagingRequiresGatedSession() {
        #expect(CMUXBackendEnvironmentOverride.staging.requiresGatedSession)
        #expect(!CMUXBackendEnvironmentOverride.production.requiresGatedSession)
    }
}
