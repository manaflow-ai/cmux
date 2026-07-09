import CoreGraphics
import Testing
@testable import CmuxSidebar

/// Pins the resizer geometry composition against the production layout constants
/// (216 / 276 / 1200 / 360, minimum-width range 120...260) so the lifted policy
/// stays byte-faithful to the app's former `ContentView` resizer methods
/// (`minimumSidebarWidth`, `maxSidebarWidth`, `normalizedSidebarWidth`,
/// `resolvedRightSidebarAvailableWidth`, `rightSidebarConfiguredMaximumWidth`,
/// `normalizedRightSidebarWidth`).
@Suite struct SidebarResizerGeometryPolicyTests {
    /// Production composition mirroring `ContentView.resizerGeometryPolicy`.
    private let policy = SidebarResizerGeometryPolicy(
        widthPolicy: SidebarWidthPolicy(
            defaultSidebarWidth: 216,
            minimumRightSidebarWidth: 276,
            maximumRightSidebarWidth: 1200,
            minimumTerminalWidthWithRightSidebar: 360
        ),
        defaultMinimumSidebarWidth: 216,
        minimumSidebarWidthRange: 120...260
    )

    @Test func minimumSidebarWidthClampsIntoRange() {
        #expect(policy.minimumSidebarWidth(setting: 200) == 200)
        #expect(policy.minimumSidebarWidth(setting: 100) == 120)
        #expect(policy.minimumSidebarWidth(setting: 400) == 260)
    }

    @Test func minimumSidebarWidthFallsBackForNonFiniteSetting() {
        #expect(policy.minimumSidebarWidth(setting: .nan) == 216)
        #expect(policy.minimumSidebarWidth(setting: .infinity) == 216)
    }

    @Test func maxSidebarWidthUsesResolvedWidthWhenPositive() {
        // 1/3 of 1200 = 400, above the minimum.
        #expect(
            policy.maxSidebarWidth(
                resolvedAvailableWidth: 1200,
                fallbackScreenWidth: 99_999,
                minimumWidth: 216
            ) == 400
        )
    }

    @Test func maxSidebarWidthUsesFallbackScreenWhenNoResolvedWidth() {
        // 1/3 of 1500 = 500.
        #expect(
            policy.maxSidebarWidth(
                resolvedAvailableWidth: nil,
                fallbackScreenWidth: 1500,
                minimumWidth: 216
            ) == 500
        )
    }

    @Test func maxSidebarWidthUsesTerminalFallbackWhenAllNil() {
        // 1/3 of the 1920 terminal fallback = 640.
        #expect(
            policy.maxSidebarWidth(
                resolvedAvailableWidth: nil,
                fallbackScreenWidth: nil,
                minimumWidth: 216
            ) == 640
        )
    }

    @Test func normalizedSidebarWidthClamps() {
        #expect(policy.normalizedSidebarWidth(180, maximumWidth: 600, minimumWidth: 216) == 216)
        #expect(policy.normalizedSidebarWidth(900, maximumWidth: 600, minimumWidth: 216) == 600)
        #expect(policy.normalizedSidebarWidth(400, maximumWidth: 600, minimumWidth: 216) == 400)
    }

    @Test func resolvedRightSidebarAvailableWidthPicksFirstNonNil() {
        #expect(
            policy.resolvedRightSidebarAvailableWidth(
                resolvedWidths: [nil, nil, 1340, 800]
            ) == 1340
        )
    }

    @Test func resolvedRightSidebarAvailableWidthFallsBackWhenAllNil() {
        #expect(policy.resolvedRightSidebarAvailableWidth(resolvedWidths: [nil, nil]) == 1920)
    }

    @Test func rightSidebarConfiguredMaximumWidthDecodesOverride() {
        // The -1 sentinel means no override is active.
        #expect(policy.rightSidebarConfiguredMaximumWidth(setting: -1) == nil)
        // A positive value decodes to a configured maximum, clamped to >= 276.
        #expect(policy.rightSidebarConfiguredMaximumWidth(setting: 900) == 900)
        #expect(policy.rightSidebarConfiguredMaximumWidth(setting: 100) == 276)
    }

    @Test func normalizedRightSidebarWidthClamps() {
        #expect(
            policy.normalizedRightSidebarWidth(900, availableWidth: 1600, configuredMaximumWidth: nil) == 900
        )
        #expect(
            policy.normalizedRightSidebarWidth(20, availableWidth: 1000, configuredMaximumWidth: nil) == 276
        )
        #expect(
            policy.normalizedRightSidebarWidth(
                10_000,
                availableWidth: 2400,
                configuredMaximumWidth: 1_500
            ) == 1_500
        )
    }
}
