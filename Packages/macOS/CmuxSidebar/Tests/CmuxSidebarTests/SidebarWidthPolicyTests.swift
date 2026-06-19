import CoreGraphics
import Testing
@testable import CmuxSidebar

/// Pins the sidebar width-clamp math against the production layout constants
/// (216 / 276 / 1200 / 360) so the lifted policy stays byte-faithful to the
/// app's former `ContentView.clampedSidebarWidth` / `clampedRightSidebarWidth`.
@Suite struct SidebarWidthPolicyTests {
    /// Production composition mirroring `ContentView.widthPolicy`.
    private let policy = SidebarWidthPolicy(
        defaultSidebarWidth: 216,
        minimumRightSidebarWidth: 276,
        maximumRightSidebarWidth: 1200,
        minimumTerminalWidthWithRightSidebar: 360
    )

    @Test func leftClampKeepsMinimumWidth() {
        #expect(policy.clampLeftSidebarWidth(184, maximumWidth: 600, minimumWidth: 216) == 216)
    }

    @Test func leftClampHonorsSmallerConfiguredMinimum() {
        #expect(policy.clampLeftSidebarWidth(184, maximumWidth: 600, minimumWidth: 160) == 184)
        #expect(policy.clampLeftSidebarWidth(140, maximumWidth: 600, minimumWidth: 160) == 160)
    }

    @Test func leftClampCollapsesNonFiniteMaximumToMinimum() {
        #expect(policy.clampLeftSidebarWidth(300, maximumWidth: .nan, minimumWidth: 216) == 216)
    }

    @Test func leftClampFallsBackToDefaultForNonFiniteCandidate() {
        #expect(policy.clampLeftSidebarWidth(.infinity, maximumWidth: 600, minimumWidth: 160) == 216)
        // Default falls back clamped into the available range.
        #expect(policy.clampLeftSidebarWidth(.nan, maximumWidth: 200, minimumWidth: 160) == 200)
    }

    @Test func rightClampAllowsWideExplorerOnLargeWindows() {
        #expect(policy.clampRightSidebarWidth(900, availableWidth: 1600) == 900)
    }

    @Test func rightClampHitsBuiltInCapOnHugeWindow() {
        #expect(policy.clampRightSidebarWidth(10_000, availableWidth: 10_000) == 1200)
    }

    @Test func rightClampLeavesTerminalWidthWhenNoConfiguredMax() {
        #expect(policy.clampRightSidebarWidth(10_000, availableWidth: 1000) == 640)
    }

    @Test func rightClampConfiguredMaxCanExceedBuiltInDefault() {
        #expect(
            policy.clampRightSidebarWidth(10_000, availableWidth: 2400, configuredMaximumWidth: 1_500) == 1_500
        )
    }

    @Test func rightClampConfiguredMaxStillLeavesTerminalWidth() {
        #expect(
            policy.clampRightSidebarWidth(10_000, availableWidth: 1000, configuredMaximumWidth: 1_400) == 640
        )
    }

    @Test func rightClampConfiguredMaxBelowMinimumClampsToMinimum() {
        #expect(
            policy.clampRightSidebarWidth(10_000, availableWidth: 1000, configuredMaximumWidth: 120) == 276
        )
    }

    @Test func rightClampKeepsMinimumWidth() {
        #expect(policy.clampRightSidebarWidth(20, availableWidth: 1000) == 276)
    }

    @Test func rightClampSanitizesNonFiniteInputs() {
        // Non-finite candidate falls back to 220, non-finite available width to 1920.
        // available 1920 -> cap min(1200, 1920-360=1560)=1200; candidate 220 is below
        // the 276 minimum, so the clamp floors it to 276.
        #expect(policy.clampRightSidebarWidth(.nan, availableWidth: .infinity) == 276)
    }
}
