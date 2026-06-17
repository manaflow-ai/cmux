import CmuxSettings
import Testing
@testable import CmuxSettingsUI

/// Smoke tests for ``SettingsSearchIndex``.
///
/// The index is the seam between the catalog (data) and the settings
/// window sidebar (UI). It is fully pure — no view-model, no actor — so
/// it can be tested without touching SwiftUI or AppKit.
@Suite("SettingsSearchIndex")
struct SettingsSearchIndexTests {
    @Test func emptyQueryReturnsAllSectionEntries() {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        let result = index.match("")
        let sectionCount = result.filter {
            if case .section = $0.kind { return true } else { return false }
        }.count
        #expect(sectionCount == SettingsSectionID.allCases.count)
    }

    @Test func tokenizedQueryFiltersBothSectionsAndSettings() {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        let result = index.match("automation")
        // At minimum the Automation section itself should match.
        #expect(result.contains(where: { $0.title == "Automation" }))
    }

    @Test func modifierHoldHintSynonymsFindKeyboardShortcutSetting() {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        let result = index.match("hotkey hint chips")
        #expect(result.contains { $0.id == "setting:keyboardShortcuts:modifier-hold-hints" })
    }

    @Test func diacriticInsensitiveMatch() {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        let plain = index.match("automation")
        let withDiacritics = index.match("autómation")
        #expect(plain.count == withDiacritics.count)
    }

    /// The search-result highlight depends on a row being able to map
    /// the dotted cmux.json path it declares (e.g. the "Show Branch +
    /// Directory in Sidebar" row's `sidebar.showBranchDirectory`) to the
    /// same anchor id the sidebar search hit carries. This is the bridge
    /// that lets `scrollTo` + the pulse find the row.
    @Test func resolvesCuratedPathToSidebarHitAnchor() {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        let anchor = index.anchorID(forSettingsPath: "sidebar.showBranchDirectory")
        #expect(anchor == "setting:sidebarAppearance:show-branch-directory")
    }

    /// A resolved anchor must correspond to a real indexed entry,
    /// otherwise the navigation layer would scroll to / highlight an id
    /// no row carries.
    @Test func resolvedAnchorMatchesAnIndexedEntry() throws {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        let anchor = try #require(index.anchorID(forSettingsPath: "terminal.copyOnSelect"))
        #expect(index.entries.contains { $0.id == anchor })
    }

    @Test func unknownPathHasNoAnchor() {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        #expect(index.anchorID(forSettingsPath: "totally.bogus.path") == nil)
    }
}
