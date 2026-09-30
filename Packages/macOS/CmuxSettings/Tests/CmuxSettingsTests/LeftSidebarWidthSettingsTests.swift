import Testing
@testable import CmuxSettings

@Suite("LeftSidebarWidthSettings")
struct LeftSidebarWidthSettingsTests {
    private let settings = LeftSidebarWidthSettings()

    @Test func defaultIsInsideTheConfigurableRange() {
        #expect(LeftSidebarWidthSettings.defaultMinimumWidth == 240)
        #expect(LeftSidebarWidthSettings.range == 120...260)
        #expect(LeftSidebarWidthSettings.range.contains(LeftSidebarWidthSettings.defaultMinimumWidth))
    }

    @Test func clampKeepsValuesInsideTheRange() {
        #expect(settings.clampedMinimumWidth(160) == 160)
        #expect(settings.clampedMinimumWidth(120) == 120)
        #expect(settings.clampedMinimumWidth(260) == 260)
    }

    @Test func clampPinsOutOfRangeValuesToTheBounds() {
        #expect(settings.clampedMinimumWidth(40) == 120)
        #expect(settings.clampedMinimumWidth(-5) == 120)
        #expect(settings.clampedMinimumWidth(10_000) == 260)
    }

    @Test func clampFallsBackToTheDefaultForNonFiniteValues() {
        #expect(settings.clampedMinimumWidth(.nan) == LeftSidebarWidthSettings.defaultMinimumWidth)
        #expect(settings.clampedMinimumWidth(.infinity) == LeftSidebarWidthSettings.defaultMinimumWidth)
    }

    @Test func catalogKeyUsesTheHistoricalDefaultsKey() {
        let key = SidebarCatalogSection().leftMinWidth
        #expect(key.id == "sidebar.leftMinWidth")
        #expect(key.userDefaultsKey == "sidebarMinimumWidth")
        #expect(key.defaultValue == LeftSidebarWidthSettings.defaultMinimumWidth)
    }
}
