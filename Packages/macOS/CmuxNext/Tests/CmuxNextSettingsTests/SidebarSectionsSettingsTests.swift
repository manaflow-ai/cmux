import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Testing

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
