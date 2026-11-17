import Foundation
import Testing
@testable import CmuxSettings

@Suite("SurfaceTabBarLayoutSettings")
struct SurfaceTabBarLayoutSettingsTests {
    private typealias Layout = SurfaceTabBarLayoutSettings

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "cmux-surface-tab-bar-layout-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    @Test func unsetKeysReadDefaults() throws {
        try withDefaults { defaults in
            let layout = Layout(defaults: defaults)
            #expect(layout.widthMode == .fixed)
            #expect(layout.maxTabWidth == 220)
            #expect(layout.height == 28)
        }
    }

    @Test func configuredValuesInsideRangesAreReadAsIs() throws {
        try withDefaults { defaults in
            defaults.set("fill", forKey: Layout.widthModeKey)
            defaults.set(320.0, forKey: Layout.maxTabWidthKey)
            defaults.set(36.0, forKey: Layout.heightKey)
            let layout = Layout(defaults: defaults)
            #expect(layout.widthMode == .fill)
            #expect(layout.maxTabWidth == 320)
            #expect(layout.height == 36)
        }
    }

    @Test func unknownWidthModeFallsBackToFixed() throws {
        try withDefaults { defaults in
            defaults.set("stretch", forKey: Layout.widthModeKey)
            #expect(Layout(defaults: defaults).widthMode == .fixed)
        }
    }

    @Test func outOfRangeNumbersAreClamped() throws {
        try withDefaults { defaults in
            defaults.set(10_000.0, forKey: Layout.maxTabWidthKey)
            defaults.set(4.0, forKey: Layout.heightKey)
            let layout = Layout(defaults: defaults)
            #expect(layout.maxTabWidth == Layout.maxTabWidthRange.upperBound)
            #expect(layout.height == Layout.heightRange.lowerBound)
        }
    }

    @Test func nonFiniteOrNonNumericValuesFallBackToDefaults() throws {
        try withDefaults { defaults in
            defaults.set(Double.nan, forKey: Layout.maxTabWidthKey)
            defaults.set("tall", forKey: Layout.heightKey)
            let layout = Layout(defaults: defaults)
            #expect(layout.maxTabWidth == Layout.defaultMaxTabWidth)
            #expect(layout.height == Layout.defaultHeight)
        }
    }

    @Test func keysAndPathsListEverySetting() {
        #expect(Layout.allKeys.count == 3)
        #expect(Layout.allPaths.allSatisfy { $0.hasPrefix("surfaceTabBar.") })
    }
}
