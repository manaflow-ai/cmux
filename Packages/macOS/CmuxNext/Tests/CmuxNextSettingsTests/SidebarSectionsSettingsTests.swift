import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `sidebar.sectionLook`, `sidebar.topBandMaxShare`, `sidebar.bottomBandMaxShare`
/// and `sidebar.pinnedBandsScroll` (plans/cmux-next/sidebar-sections.md 7).
@Suite struct SidebarSectionsSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsAreQuietWithAThirdAndAQuarter() throws {
        let snapshot = try parse("{}")
        #expect(snapshot.sidebarSections == SidebarSectionsPreferences(look: "quiet", topBandMaxShare: 1.0 / 3.0,
                                                                         bottomBandMaxShare: 0.25, pinnedBandsScroll: true))
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func readsEveryKey() throws {
        let snapshot = try parse(#"{"sidebar": {"sectionLook": "lines", "topBandMaxShare": 0.5, "bottomBandMaxShare": 0.2, "pinnedBandsScroll": false, "showWorkspaceTabs": true}}"#)
        #expect(snapshot.sidebarSections == SidebarSectionsPreferences(look: "lines", topBandMaxShare: 0.5, bottomBandMaxShare: 0.2,
                                                                         pinnedBandsScroll: false, showWorkspaceTabs: true))
    }

    @Test func badValuesKeepDefaultsWithDiagnostics() throws {
        let snapshot = try parse(#"{"sidebar": {"sectionLook": "fancy", "topBandMaxShare": 2, "pinnedBandsScroll": "no", "showWorkspaceTabs": "yes"}}"#)
        #expect(snapshot.sidebarSections == .defaults)
        #expect(Set(snapshot.diagnostics.map(\.path)) == ["sidebar.sectionLook", "sidebar.topBandMaxShare", "sidebar.pinnedBandsScroll", "sidebar.showWorkspaceTabs"])
    }

    @Test func chatsAreHiddenByDefaultAndOptIn() throws {
        #expect(try !parse("{}").sidebarSections.showChats)
        #expect(try parse(#"{"sidebar": {"showChats": true}}"#).sidebarSections.showChats)
        let bad = try parse(#"{"sidebar": {"showChats": "yes"}}"#)
        #expect(bad.sidebarSections == .defaults)
        #expect(bad.diagnostics.map(\.path) == ["sidebar.showChats"])
        let descriptor = try #require(SettingsSchema.all.first { $0.path == ["sidebar", "showChats"] })
        #expect(descriptor.section == .appearance)
        #expect(SettingsSchema.agentSettable(descriptor) == true)
    }

    /// The S1 key is still read for one release when the new key is absent.
    @Test func countsAreOptIn() throws {
        #expect(try !parse("{}").sidebarSections.workspaceRow.base.shows(.tabCount))
        #expect(try parse(#"{"sidebar": {"showCounts": true}}"#).sidebarSections.workspaceRow.base.shows(.tabCount))
        let bad = try parse(#"{"sidebar": {"showCounts": 1}}"#)
        #expect(bad.sidebarSections == .defaults)
        #expect(bad.diagnostics.map(\.path) == ["sidebar.showCounts"])
    }

    /// S1: rows are one line unless the folder line is turned on.
    @Test func theWorkspaceFolderLineIsOptIn() throws {
        #expect(try !parse("{}").sidebarSections.workspaceRow.base.shows(.directory))
        #expect(try parse(#"{"sidebar": {"showWorkspaceDirectory": true}}"#).sidebarSections.workspaceRow.base.shows(.directory))
        let bad = try parse(#"{"sidebar": {"showWorkspaceDirectory": "yes"}}"#)
        #expect(bad.sidebarSections == .defaults)
        #expect(bad.diagnostics.map(\.path) == ["sidebar.showWorkspaceDirectory"])
        let descriptor = try #require(SettingsSchema.all.first { $0.path == ["sidebar", "workspaceRow", "directory"] })
        #expect(descriptor.section == .appearance)
    }

    /// One nested-tabs key: `sidebar.showWorkspaceTabs` (#17186). An
    /// unshipped `sidebar.nestedTabs` is not a setting.
    @Test func nestedTabsIsNotASecondKey() {
        #expect(!SettingsSchema.all.contains { $0.path == ["sidebar", "nestedTabs"] })
    }

    /// R87: nightly-next builds wrote `sidebar.stickyBandsScroll`; it is
    /// read for one release, and the new key wins when both are set.
    @Test func theOldStickyBandsKeyIsReadForOneRelease() throws {
        #expect(try parse(#"{"sidebar": {"stickyBandsScroll": false}}"#).sidebarSections.pinnedBandsScroll == false)
        #expect(try parse(#"{"sidebar": {"stickyBandsScroll": false, "pinnedBandsScroll": true}}"#).sidebarSections.pinnedBandsScroll)
        let bad = try parse(#"{"sidebar": {"stickyBandsScroll": "no"}}"#)
        #expect(bad.diagnostics.map(\.path) == ["sidebar.stickyBandsScroll"])
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
