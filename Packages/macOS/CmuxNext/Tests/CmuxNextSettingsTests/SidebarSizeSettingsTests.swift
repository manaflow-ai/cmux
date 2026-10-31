import CmuxNextDesign
@testable import CmuxNextSettings
import Testing

/// #28663: Settings has a Sidebar section whose Size and Spacing card sets the sidebar's text size,
/// density and row spacing; cmux.json, `cmux settings set` and Cmd+Shift+P reach the same keys.
/// Unset, the sidebar keeps its text size and compact rows, and Interface Scale starts two steps
/// above 100%.
struct SidebarSizeSettingsTests {
    static func parse(_ sidebar: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["sidebar": .object(sidebar)]), validDensities: [], validMetrics: [])
    }

    @Test func settingsHasASidebarSectionLedBySizeAndSpacing() throws {
        let categories = SettingsPageLayout().categories()
        let category = try #require(categories.first { $0.spec.id == "sidebar" })
        #expect(category.spec.title.text == "Sidebar")
        let size = try #require(category.groups.first)
        #expect(size.title.text == "Size and Spacing")
        #expect(size.rows == ["sidebar.textSize", "sidebar.density", "sidebar.rowSpacing"])
        #expect(category.groups.contains { $0.key == "settings.group.sidebar" })
        #expect(category.groups.contains { $0.key == "settings.group.workspaceRows" })
        let appearance = try #require(categories.first { $0.spec.id == "appearance" })
        #expect(!appearance.groups.contains { $0.key == "settings.group.sidebar" }, "a row has one home")
        let elsewhere = categories.filter { $0.spec.id != "sidebar" }.flatMap(\.groups).flatMap(\.rows)
        #expect(!elsewhere.contains("sidebar.textSize") && !elsewhere.contains("sidebar.rowSpacing"))
    }

    @Test func defaultsAreNoSmallerThanBefore() {
        let snapshot = Self.parse([:])
        #expect(snapshot.sidebarSections.density == .compact)
        #expect(snapshot.sidebarSections.textSize == .standard)
        #expect(snapshot.sidebarSections.rowSpacing == nil)
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
    }

    @Test func theUserSetsSizeDensityAndSpacing() {
        let snapshot = Self.parse(["density": .string("comfortable"), "rowSpacing": .number(6)])
        #expect(snapshot.sidebarSections.density == .comfortable)
        #expect(snapshot.sidebarSections.rowSpacing == 6)
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
    }

    @Test func outOfRangeClampsAndBadValuesSayWhy() {
        let clamped = Self.parse(["rowSpacing": .number(40)])
        #expect(clamped.sidebarSections.rowSpacing == SidebarSectionsPreferences.rowSpacingRange.upperBound)
        #expect(clamped.diagnostics.contains { $0.path == "sidebar.rowSpacing" })
        #expect(Self.parse(["rowSpacing": .number(-3)]).sidebarSections.rowSpacing == 0)
        let bad = Self.parse(["rowSpacing": .string("wide")])
        #expect(bad.sidebarSections.rowSpacing == nil)
        #expect(bad.diagnostics.contains { $0.path == "sidebar.rowSpacing" })
    }

    @Test func everySurfaceListsRowSpacing() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["sidebar", "rowSpacing"]))
        #expect(descriptor.defaultValue == nil)
        #expect(descriptor.isPaletteExposed, "Cmd+Shift+P lists sidebar.rowSpacing")
        #expect(descriptor.isShownOnSettingsPage)
    }

    @Test func interfaceScaleDefaultsTwoStepsAbove100Percent() throws {
        let scale = UIScaleSetting()
        #expect(abs(scale.fallback - (1 + 2 * scale.step)) < 0.0001)
        #expect(CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: []).uiScale == scale.fallback)
        let descriptor = try #require(SettingsSchema.descriptor(for: scale.configPath))
        #expect(descriptor.defaultValue == .number(scale.fallback))
    }
}
