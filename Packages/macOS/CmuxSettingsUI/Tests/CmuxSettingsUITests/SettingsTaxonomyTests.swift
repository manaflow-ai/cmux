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
        #expect(SettingsTaxonomyGroup.general.sections == [.account, .app, .themes, .sleepyMode])
        #expect(SettingsTaxonomyGroup.terminal.sections == [.terminal, .textBox])
        #expect(SettingsTaxonomyGroup.workspace.sections == [.workspaceColors])
        #expect(SettingsTaxonomyGroup.sidebarAndDock.sections == [.sidebarAppearance, .customSidebars])
        #expect(SettingsTaxonomyGroup.agentsAndAutomation.sections == [.voice, .automation, .computerUse])
        #expect(SettingsTaxonomyGroup.browserAndFiles.sections == [.browser, .browserImport])
        #expect(SettingsTaxonomyGroup.remoteAndDevices.sections == [.mobile, .cloudMachines, .computers, .networking])
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
        #expect(sectionEntries.map(\.id) == SettingsSectionID.allCases.map { "section:\($0.rawValue)" })

        for section in SettingsTaxonomyGroup.sectionsInDisplayOrder {
            let entryID = "section:\(section.rawValue)"
            let entry = try #require(entriesByID[entryID])
            #expect(entry.anchorID == entryID)
            #expect(entry.kind == .section)
        }
    }

    /// Every theme setting lives on the Themes page, whichever cmux.json
    /// namespace owns it, so search results for them open that page.
    @Test func themeSettingsResolveToTheThemesSection() throws {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        #expect(index.anchorID(forSettingsPath: "app.accentColor") == "setting:themes:accent-color")
        #expect(index.anchorID(forSettingsPath: "terminal.adaptiveDefaultTheme") == "setting:themes:adaptive-default-theme")
        #expect(index.anchorID(forSettingsPath: "browser.theme") == "setting:themes:browser-theme")

        let hits = index.match("terminal theme")
        let terminalTheme = try #require(hits.first { $0.id == "setting:themes:terminal-theme" })
        #expect(terminalTheme.anchorID == "setting:themes:terminal-theme")
    }

    /// Ensures every visible taxonomy header resolves to nonempty localized copy.
    @Test func everyGroupHasALocalizedTitle() {
        for group in SettingsTaxonomyGroup.allCases {
            #expect(!group.title.isEmpty)
        }
    }
}
