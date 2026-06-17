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
        #expect(MobileUnifiedMultiMacFlag.isEnabled(
            environment: [:], defaults: emptyDefaults(), isDebugBuild: true
        ) == true)
        #expect(MobileUnifiedMultiMacFlag.isEnabled(
            environment: [:], defaults: emptyDefaults(), isDebugBuild: false
        ) == false)
    }

    @Test func envOverrideWinsBothDirections() {
        // Force ON on a release build.
        #expect(MobileUnifiedMultiMacFlag.isEnabled(
            environment: ["CMUX_UNIFIED_MULTI_MAC": "1"],
            defaults: emptyDefaults(),
            isDebugBuild: false
        ) == true)
        // Force OFF on a debug build.
        #expect(MobileUnifiedMultiMacFlag.isEnabled(
            environment: ["CMUX_UNIFIED_MULTI_MAC": "false"],
            defaults: emptyDefaults(),
            isDebugBuild: true
        ) == false)
    }

    @Test func defaultsOverrideWinsOverBuildType() {
        let on = emptyDefaults()
        on.set(true, forKey: "unifiedMultiMacEnabled")
        #expect(MobileUnifiedMultiMacFlag.isEnabled(
            environment: [:], defaults: on, isDebugBuild: false
        ) == true)

        let off = emptyDefaults()
        off.set(false, forKey: "unifiedMultiMacEnabled")
        #expect(MobileUnifiedMultiMacFlag.isEnabled(
            environment: [:], defaults: off, isDebugBuild: true
        ) == false)
    }

    @Test func envOverrideBeatsDefaultsOverride() {
        let defaults = emptyDefaults()
        defaults.set(false, forKey: "unifiedMultiMacEnabled")
        #expect(MobileUnifiedMultiMacFlag.isEnabled(
            environment: ["CMUX_UNIFIED_MULTI_MAC": "on"],
            defaults: defaults,
            isDebugBuild: false
        ) == true)
    }

    @Test func blankEnvIsIgnored() {
        #expect(MobileUnifiedMultiMacFlag.isEnabled(
            environment: ["CMUX_UNIFIED_MULTI_MAC": "  "],
            defaults: emptyDefaults(),
            isDebugBuild: false
        ) == false)
    }
}
