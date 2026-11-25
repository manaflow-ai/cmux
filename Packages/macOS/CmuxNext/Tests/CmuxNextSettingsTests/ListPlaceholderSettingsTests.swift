@testable import CmuxNextSettings
import Foundation
import Testing

/// A free-text list row names the placeholder its empty field shows (`SettingDescriptor.placeholder`),
/// and the export hands it to the Settings page, so a list of words or rules never shows the host
/// example "example.com" (a1018, 2026-11-06). A localized instruction carries its catalog key; a
/// syntax example (a host, a rule) is not translated, so it has none. A row without one exports null.
struct ListPlaceholderSettingsTests {
    @Test(arguments: [
        (["chief", "subagentSidebarShowWords"], "settings.placeholder.wordOrPhrase"),
        (["chief", "subagentSidebarHideWords"], "settings.placeholder.wordOrPhrase"),
        (["agents", "trust", "ownOrgs"], "settings.placeholder.githubOwner"),
    ])
    func instructionPlaceholdersAreLocalized(path: [String], key: String) throws {
        let row = try #require(SettingsSchema.descriptor(for: path))
        #expect(row.placeholder?.key == key, "\(row.id)")
        #expect(row.placeholder?.text.isEmpty == false, "\(row.id)")
    }

    @Test(arguments: [
        (["ssh", "linkAllowedHosts"], "devbox.local"),
        (["terminal", "linkOpener", "rules"], "caller:gh github.com -> safari"),
        (["browser", "urlsToAlwaysOpenExternally"], "*.example.com/*"),
    ])
    func syntaxPlaceholdersAreExamples(path: [String], example: String) throws {
        let row = try #require(SettingsSchema.descriptor(for: path))
        #expect(row.placeholder == SettingText(key: nil, text: example), "\(row.id)")
    }

    @Test func theExportCarriesThePlaceholderOrNull() throws {
        let text: (String, String?) -> [String: Any] = { ["text": $0, "key": $1 as Any? ?? NSNull()] }
        let words = try #require(SettingsSchema.descriptor(for: ["chief", "subagentSidebarShowWords"]))
        let exported = try #require(SettingsSchemaExport().row(for: words, text: text)["placeholder"] as? [String: Any])
        #expect(exported["key"] as? String == "settings.placeholder.wordOrPhrase")
        #expect(exported["text"] as? String == words.placeholder?.text)
        let mode = try #require(SettingsSchema.descriptor(for: ["chief", "subagentSidebar"]))
        #expect(SettingsSchemaExport().row(for: mode, text: text)["placeholder"] is NSNull)
    }
}
