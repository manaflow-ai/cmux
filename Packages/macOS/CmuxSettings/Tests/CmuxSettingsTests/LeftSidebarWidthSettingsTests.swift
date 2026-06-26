import Testing
@testable import CmuxSettings

@Suite("LeftSidebarWidthSettings")
struct LeftSidebarWidthSettingsTests {
    private let settings = LeftSidebarWidthSettings()

    @Test func defaultMatchesHistoricalFloor() {
        #expect(LeftSidebarWidthSettings.defaultMinimumWidth == 216)
        #expect(LeftSidebarWidthSettings.range.contains(LeftSidebarWidthSettings.defaultMinimumWidth))
    }

    @Test func rangeAllowsNarrowerThanHistoricalMinimum() {
        // The point of issue #6784: the floor must be configurable below 216.
        #expect(LeftSidebarWidthSettings.lowerBound < 216)
        #expect(LeftSidebarWidthSettings.lowerBound == 100)
        #expect(LeftSidebarWidthSettings.upperBound == 260)
    }

    @Test func clampHonorsConfiguredValueWithinRange() {
        #expect(settings.clampedMinimumWidth(120) == 120)
        #expect(settings.clampedMinimumWidth(216) == 216)
    }

    @Test func clampPinsOutOfRangeValuesToBounds() {
        #expect(settings.clampedMinimumWidth(40) == LeftSidebarWidthSettings.lowerBound)
        #expect(settings.clampedMinimumWidth(10_000) == LeftSidebarWidthSettings.upperBound)
    }

    @Test func clampFallsBackToDefaultForNonFiniteValues() {
        #expect(settings.clampedMinimumWidth(.nan) == LeftSidebarWidthSettings.defaultMinimumWidth)
        #expect(settings.clampedMinimumWidth(.infinity) == LeftSidebarWidthSettings.defaultMinimumWidth)
    }

    @Test func identifiersAreStable() {
        #expect(LeftSidebarWidthSettings.jsonKey == "leftMinWidth")
        #expect(LeftSidebarWidthSettings.settingsPath == "sidebar.leftMinWidth")
        #expect(LeftSidebarWidthSettings.minimumWidthKey == "sidebarMinimumWidth")
    }
}
