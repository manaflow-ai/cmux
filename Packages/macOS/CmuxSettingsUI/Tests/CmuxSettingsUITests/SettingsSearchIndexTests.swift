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

    /// Typing an exact section name navigates to that section first.
    /// Child settings' dotted-path synonyms (e.g. "automation.*") also
    /// match the query and carry a +20 bonus, so without an exact-title
    /// boost they floated above the section. Guards that ranking regression.
    @Test func exactSectionNameRanksSectionFirst() throws {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        let first = try #require(index.match("automation").first)
        #expect(first.kind == .section)
        #expect(first.title == "Automation")
    }

    @Test func modifierHoldHintSynonymsFindKeyboardShortcutSetting() {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        let result = index.match("hotkey hint chips")
        #expect(result.contains { $0.id == "setting:keyboardShortcuts:modifier-hold-hints" })
    }

    @Test(arguments: [
        ("naming", "setting:automation:workspace-auto-naming"),
        ("nmaing", "setting:automation:workspace-auto-naming"),
        ("auto name", "setting:automation:workspace-auto-naming"),
        ("rename workspace", "setting:automation:workspace-auto-naming"),
        ("naming agent", "setting:automation:workspace-auto-naming"),
        ("automation.autoNamingAgent", "setting:automation:workspace-auto-naming"),
        ("autoNamingAgent", "setting:automation:workspace-auto-naming"),
        ("option as alt", "setting:app:terminal-config"),
        ("option", "setting:app:terminal-config"),
        ("environment variables", "setting:app:notification-command"),
    ])
    func searchesFindRealSettingsRows(query: String, expectedID: String) {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        let result = index.match(query)
        #expect(
            result.contains { $0.id == expectedID },
            "Expected settings search for '\(query)' to include \(expectedID), got \(result.map(\.id))"
        )
    }

    @Test(arguments: [
        ("browser settings", [
            "setting:browser:search-engine",
            "setting:browser:terminal-links",
            "setting:browser:http-allowlist",
        ]),
        ("notification settings", [
            "setting:app:dock-badge",
            "setting:app:desktop-notifications",
            "setting:app:notification-sound",
            "setting:app:notification-command",
        ]),
        ("shortcut split right", [
            "setting:keyboardShortcuts:shortcuts",
        ]),
        ("browzer lniks", [
            "setting:browser:terminal-links",
        ]),
        ("canvas", [
            "setting:app:canvas-pane-gap",
            "setting:app:canvas-snapping",
            "setting:keyboardShortcuts:shortcuts",
        ]),
    ])
    func fuzzyKeywordQueriesSurfaceRelatedSettings(query: String, expectedIDs: [String]) {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        let resultIDs = Set(index.match(query).map(\.id))
        #expect(
            expectedIDs.allSatisfy { resultIDs.contains($0) },
            "Expected settings search for '\(query)' to include \(expectedIDs), got \(resultIDs.sorted())"
        )
    }

    @Test func exactAndSubstringMatchesRankAheadOfFuzzyFallbacks() throws {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        #expect(try #require(index.match("Terminal Config").first).id == "setting:app:terminal-config")
        #expect(try #require(index.match("copy on select").first).id == "setting:terminal:copy-on-select")
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

    @Test func conditionalAutoNamingAgentSearchUsesVisibleWorkspaceAutoNamingRow() throws {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        #expect(index.anchorID(forSettingsPath: "automation.autoNamingAgent") == nil)
        let hit = try #require(index.match("naming agent").first {
            $0.id == "setting:automation:workspace-auto-naming"
        })
        #expect(hit.anchorID == "setting:automation:workspace-auto-naming")
    }

    @Test(arguments: [
        ("welcome shown", "Welcome Shown"),
        ("selected team id", "Selected Team ID"),
        ("import hint dismissed", "Import Hint Dismissed"),
        ("dev window display", "Dev Window Display"),
        ("notification hooks", "Hooks"),
        ("notification hooks mode", "Hooks Mode"),
    ])
    func rawCatalogOnlyKeysDoNotSurfaceAsSettingsRows(query: String, hiddenTitle: String) {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        let hiddenHits = index.match(query).filter { entry in
            if case .setting = entry.kind {
                return entry.title == hiddenTitle
            }
            return false
        }
        #expect(
            hiddenHits.isEmpty,
            "Expected settings search for '\(query)' not to surface hidden catalog key '\(hiddenTitle)'"
        )
    }

    /// A resolved anchor must correspond to a real indexed entry,
    /// otherwise the navigation layer would scroll to / highlight an id
    /// no row carries.
    @Test func resolvedAnchorMatchesAnIndexedEntry() throws {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        let anchor = try #require(index.anchorID(forSettingsPath: "terminal.copyOnSelect"))
        #expect(index.entries.contains { $0.id == anchor })
    }

    /// The auto-naming card renders two rows: the toggle and, when
    /// enabled, the Naming Agent picker. Only the toggle's path may anchor
    /// the workspace-auto-naming entry; the picker's `automation.autoNamingAgent`
    /// path must NOT resolve to it, or both rendered rows would carry the
    /// same scroll `.id` and `scrollTo` would be ambiguous (the collision
    /// guarded by ``SettingsRowAnchorResolutionTests/rowAnchorsAreUniqueAcrossRows``).
    /// "naming agent" stays searchable via the entry's text synonyms.
    @Test func autoNamingTogglePathAnchorsCardWithoutAgentPickerCollision() {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        #expect(index.anchorID(forSettingsPath: "automation.workspaceAutoNaming") == "setting:automation:workspace-auto-naming")
        #expect(index.anchorID(forSettingsPath: "automation.autoNamingAgent") == nil)
    }

    @Test func localizedAutoNamingAliasesRemainSearchableWithoutAgentPickerCollision() {
        let index = SettingsSearchIndex(
            catalog: SettingCatalog(),
            curatedEntries: [
                .init(
                    section: .automation,
                    id: "workspace-auto-naming",
                    title: "Workspace Auto-Naming",
                    synonyms: "automation.workspaceAutoNaming automation.autoNamingAgent 命名 エージェント",
                    anchorPath: "automation.workspaceAutoNaming"
                ),
            ]
        )

        #expect(index.match("命名 エージェント").contains { $0.id == "setting:automation:workspace-auto-naming" })
        #expect(index.anchorID(forSettingsPath: "automation.workspaceAutoNaming") == "setting:automation:workspace-auto-naming")
        #expect(index.anchorID(forSettingsPath: "automation.autoNamingAgent") == nil)
    }

    @Test func unknownPathHasNoAnchor() {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        #expect(index.anchorID(forSettingsPath: "totally.bogus.path") == nil)
    }
}
