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

/// Review MED1: the two band shares together leave the list at least a
/// fifth of the sidebar: past 0.8 both shrink in proportion, no diagnostic.
@Suite struct SidebarBandShareSumTests {
    @Test func sharesSummingPastTheCapShrinkInProportion() throws {
        let snapshot = CmuxConfigSnapshot.parse(
            try JSONC.parse(#"{"sidebar": {"topBandMaxShare": 0.6, "bottomBandMaxShare": 0.4}}"#), validDensities: [], validMetrics: [])
        let p = snapshot.sidebarSections
        #expect(abs(p.topBandMaxShare + p.bottomBandMaxShare - 0.8) < 1e-9)
        #expect(abs(p.topBandMaxShare / p.bottomBandMaxShare - 1.5) < 1e-9)
        #expect(snapshot.diagnostics.isEmpty)
    }
}
