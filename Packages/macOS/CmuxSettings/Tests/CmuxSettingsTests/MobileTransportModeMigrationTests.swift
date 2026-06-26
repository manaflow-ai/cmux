import Foundation
import Testing
@testable import CmuxSettings

@Suite("MobileTransportModeMigration")
struct MobileTransportModeMigrationTests {
    /// An isolated UserDefaults suite so tests never touch the real domain.
    private func makeDefaults() -> UserDefaults {
        let suite = "dev.cmux.tests.transportMode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func derivedMode_irohOn_isCmuxRelay() {
        #expect(MobileTransportModeMigration.derivedMode(hadIroh: true, hadPairing: false) == .cmuxRelay)
        #expect(MobileTransportModeMigration.derivedMode(hadIroh: true, hadPairing: true) == .cmuxRelay)
    }

    @Test func derivedMode_irohOffPairingOn_isTailscale() {
        #expect(MobileTransportModeMigration.derivedMode(hadIroh: false, hadPairing: true) == .tailscale)
    }

    @Test func derivedMode_bothOffOrUnset_isCmuxRelay() {
        #expect(MobileTransportModeMigration.derivedMode(hadIroh: false, hadPairing: false) == .cmuxRelay)
        #expect(MobileTransportModeMigration.derivedMode(hadIroh: nil, hadPairing: nil) == .cmuxRelay)
    }

    @Test func runIfNeeded_migratesIrohOnToCmuxRelay_andClearsLegacyKeys() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: MobileTransportModeMigration.legacyIrohKey)

        MobileTransportModeMigration.runIfNeeded(defaults: defaults)

        #expect(defaults.string(forKey: MobileTransportModeMigration.modeKey) == MobileTransportMode.cmuxRelay.rawValue)
        #expect(defaults.object(forKey: MobileTransportModeMigration.legacyIrohKey) == nil)
    }

    @Test func runIfNeeded_migratesPairingOnlyToTailscale() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: MobileTransportModeMigration.legacyIrohKey)
        defaults.set(true, forKey: MobileTransportModeMigration.legacyPairingKey)

        MobileTransportModeMigration.runIfNeeded(defaults: defaults)

        #expect(defaults.string(forKey: MobileTransportModeMigration.modeKey) == MobileTransportMode.tailscale.rawValue)
        #expect(defaults.object(forKey: MobileTransportModeMigration.legacyPairingKey) == nil)
    }

    @Test func runIfNeeded_freshInstall_leavesModeUnset() {
        let defaults = makeDefaults()

        MobileTransportModeMigration.runIfNeeded(defaults: defaults)

        // No legacy keys: leave the mode unset so the catalog default applies and
        // onboarding makes the choice explicit.
        #expect(defaults.object(forKey: MobileTransportModeMigration.modeKey) == nil)
    }

    @Test func runIfNeeded_isNoOpWhenModeAlreadySet() {
        let defaults = makeDefaults()
        defaults.set(MobileTransportMode.tailscale.rawValue, forKey: MobileTransportModeMigration.modeKey)
        // Legacy iroh=on would otherwise derive cmuxRelay; an explicit mode wins.
        defaults.set(true, forKey: MobileTransportModeMigration.legacyIrohKey)

        MobileTransportModeMigration.runIfNeeded(defaults: defaults)

        #expect(defaults.string(forKey: MobileTransportModeMigration.modeKey) == MobileTransportMode.tailscale.rawValue)
    }
}
