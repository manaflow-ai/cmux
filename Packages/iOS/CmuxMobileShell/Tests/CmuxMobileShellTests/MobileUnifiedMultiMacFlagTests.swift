import Foundation
import Testing
@testable import CmuxMobileShell

/// Resolution tests for ``MobileUnifiedMultiMacFlag``: build default, env
/// override, and UserDefaults override, mirroring the presence-service URL
/// resolution pattern.
@Suite struct MobileUnifiedMultiMacFlagTests {
    private func emptyDefaults() -> UserDefaults {
        let suite = "unified-flag-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func defaultsToBuildTypeWhenNoOverride() {
        #expect(MobileUnifiedMultiMacFlag(
            environment: [:], defaults: emptyDefaults(), isDebugBuild: true
        ).isEnabled == true)
        #expect(MobileUnifiedMultiMacFlag(
            environment: [:], defaults: emptyDefaults(), isDebugBuild: false
        ).isEnabled == false)
    }

    @Test func envOverrideWinsBothDirections() {
        // Force ON on a release build.
        #expect(MobileUnifiedMultiMacFlag(
            environment: ["CMUX_UNIFIED_MULTI_MAC": "1"],
            defaults: emptyDefaults(),
            isDebugBuild: false
        ).isEnabled == true)
        // Force OFF on a debug build.
        #expect(MobileUnifiedMultiMacFlag(
            environment: ["CMUX_UNIFIED_MULTI_MAC": "false"],
            defaults: emptyDefaults(),
            isDebugBuild: true
        ).isEnabled == false)
    }

    @Test func defaultsOverrideWinsOverBuildType() {
        let on = emptyDefaults()
        on.set(true, forKey: "unifiedMultiMacEnabled")
        #expect(MobileUnifiedMultiMacFlag(
            environment: [:], defaults: on, isDebugBuild: false
        ).isEnabled == true)

        let off = emptyDefaults()
        off.set(false, forKey: "unifiedMultiMacEnabled")
        #expect(MobileUnifiedMultiMacFlag(
            environment: [:], defaults: off, isDebugBuild: true
        ).isEnabled == false)
    }

    @Test func envOverrideBeatsDefaultsOverride() {
        let defaults = emptyDefaults()
        defaults.set(false, forKey: "unifiedMultiMacEnabled")
        #expect(MobileUnifiedMultiMacFlag(
            environment: ["CMUX_UNIFIED_MULTI_MAC": "on"],
            defaults: defaults,
            isDebugBuild: false
        ).isEnabled == true)
    }

    @Test func blankEnvIsIgnored() {
        #expect(MobileUnifiedMultiMacFlag(
            environment: ["CMUX_UNIFIED_MULTI_MAC": "  "],
            defaults: emptyDefaults(),
            isDebugBuild: false
        ).isEnabled == false)
    }
}
