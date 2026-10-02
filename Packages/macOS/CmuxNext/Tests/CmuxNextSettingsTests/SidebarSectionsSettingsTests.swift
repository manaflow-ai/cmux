import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `sidebar.sectionLook`, `sidebar.topBandMaxShare`, `sidebar.bottomBandMaxShare`
/// and `sidebar.stickyBandsScroll` (plans/cmux-next/sidebar-sections.md 7).
@Suite struct SidebarSectionsSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsAreQuietWithAThirdAndAQuarter() throws {
        let snapshot = try parse("{}")
        #expect(snapshot.sidebarSections == SidebarSectionsPreferences(look: "quiet", topBandMaxShare: 1.0 / 3.0,
                                                                         bottomBandMaxShare: 0.25, stickyBandsScroll: true))
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func readsEveryKey() throws {
        let snapshot = try parse(#"{"sidebar": {"sectionLook": "lines", "topBandMaxShare": 0.5, "bottomBandMaxShare": 0.2, "stickyBandsScroll": false}}"#)
        #expect(snapshot.sidebarSections == SidebarSectionsPreferences(look: "lines", topBandMaxShare: 0.5, bottomBandMaxShare: 0.2,
                                                                         stickyBandsScroll: false))
    }

    @Test func badValuesKeepDefaultsWithDiagnostics() throws {
        let snapshot = try parse(#"{"sidebar": {"sectionLook": "fancy", "topBandMaxShare": 2, "stickyBandsScroll": "no"}}"#)
        #expect(snapshot.sidebarSections == .defaults)
        #expect(Set(snapshot.diagnostics.map(\.path)) == ["sidebar.sectionLook", "sidebar.topBandMaxShare", "sidebar.stickyBandsScroll"])
    }

    @MainActor @Test func appliesToDesignSettings() throws {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry.standard())
        applier.apply(try parse(#"{"sidebar": {"sectionLook": "card"}}"#))
        #expect(design.sidebarSections.look == "card")
        applier.apply(try parse("{}"))
        #expect(design.sidebarSections == .defaults)
    }
}

/// Review MED1: the two band shares together must leave room for the list.
@Suite struct SidebarBandShareSumTests {
    @Test func sharesSummingPastTheCapFallBackWithADiagnostic() throws {
        let snapshot = CmuxConfigSnapshot.parse(
            try JSONC.parse(#"{"sidebar": {"topBandMaxShare": 0.6, "bottomBandMaxShare": 0.5}}"#), validDensities: [], validMetrics: [])
        #expect(snapshot.sidebarSections.topBandMaxShare == SidebarSectionsPreferences.defaults.topBandMaxShare)
        #expect(snapshot.sidebarSections.bottomBandMaxShare == SidebarSectionsPreferences.defaults.bottomBandMaxShare)
        #expect(snapshot.diagnostics.map(\.path) == ["sidebar.bottomBandMaxShare"])
    }
}
