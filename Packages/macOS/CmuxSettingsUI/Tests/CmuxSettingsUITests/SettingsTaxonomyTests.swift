import CmuxSettings
import Testing
@testable import CmuxSettingsUI

@Suite("Settings taxonomy")
struct SettingsTaxonomyTests {
    /// Guards against duplicate or missing destinations when taxonomy changes.
    @Test func everyNavigationLeafAppearsExactlyOnce() {
        let sections = SettingsTaxonomyGroup.sectionsInDisplayOrder

        #expect(sections.count == SettingsSectionID.allCases.count)
        #expect(Set(sections).count == sections.count)
        #expect(Set(sections) == Set(SettingsSectionID.allCases))
    }

    /// Locks the intended concept-to-leaf mapping for the browse sidebar.
    @Test func groupsFollowTheBrowseTaxonomy() {
        #expect(SettingsTaxonomyGroup.general.sections == [.account, .app, .sleepyMode])
        #expect(SettingsTaxonomyGroup.terminal.sections == [.terminal, .textBox])
        #expect(SettingsTaxonomyGroup.workspace.sections == [.workspaceColors])
        #expect(SettingsTaxonomyGroup.sidebarAndDock.sections == [.sidebarAppearance, .customSidebars])
        #expect(SettingsTaxonomyGroup.agentsAndAutomation.sections == [.automation, .computerUse])
        #expect(SettingsTaxonomyGroup.browserAndFiles.sections == [.browser, .browserImport])
        #expect(SettingsTaxonomyGroup.remoteAndDevices.sections == [.mobile, .cloudMachines, .networking])
        #expect(
            SettingsTaxonomyGroup.keyboardAndAdvanced.sections
                == [.globalHotkey, .keyboardShortcuts, .betaFeatures, .settingsJSON, .reset]
        )
    }

    /// Verifies grouping leaves the search/deep-link section identities intact.
    @Test func taxonomyKeepsExistingSectionSearchIdentities() throws {
        let index = SettingsSearchIndex(catalog: SettingCatalog(), curatedEntries: [])
        let sectionEntries = index.match("")
        let entriesByID = Dictionary(uniqueKeysWithValues: sectionEntries.map { ($0.id, $0) })

        // Search keeps its original declaration order and stable IDs.
        // Taxonomy is only the empty-query browse presentation.
        #expect(
            sectionEntries.map(\.id)
                == SettingsSectionID.allCases.map { "section:\($0.rawValue)" }
        )

        for section in SettingsTaxonomyGroup.sectionsInDisplayOrder {
            let entryID = "section:\(section.rawValue)"
            let entry = try #require(entriesByID[entryID])
            #expect(entry.anchorID == entryID)
            #expect(entry.kind == .section)
        }
    }

    /// Ensures every visible taxonomy header resolves to nonempty localized copy.
    @Test func everyGroupHasALocalizedTitle() {
        for group in SettingsTaxonomyGroup.allCases {
            #expect(!group.title.isEmpty)
        }
    }
}
