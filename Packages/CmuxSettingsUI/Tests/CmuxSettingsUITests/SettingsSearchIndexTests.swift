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

    @Test func diacriticInsensitiveMatch() {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        let plain = index.match("automation")
        let withDiacritics = index.match("autómation")
        #expect(plain.count == withDiacritics.count)
    }
}
