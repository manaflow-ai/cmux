@testable import CmuxNextSettings
import Foundation
import Testing

/// The Settings page layout (categories, group cards, their order and titles)
/// is defined once in the schema and exported under `page`; the web page and
/// the GPUI client render it from the export (layer-ownership.md L5). These
/// tests read the export document, the same bytes those clients read.
@Suite struct SettingsPageLayoutTests {
    static func document() throws -> [String: Any] {
        let json = try SettingsSchemaExport().json(catalog: SettingsSchemaExportTests.catalog())
        return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    static func categories(_ document: [String: Any]) throws -> [[String: Any]] {
        let page = try #require(document["page"] as? [String: Any], "the export has no page layout")
        return try #require(page["categories"] as? [[String: Any]])
    }

    @Test func exportCarriesTheApprovedCategoriesInOrder() throws {
        let document = try Self.document()
        let ids = try Self.categories(document).compactMap { $0["id"] as? String }
        #expect(ids == ["general", "theme", "appearance", "terminal", "agents", "notifications", "browser",
                        "keyboard", "privacy", "accounts", "advanced", "experimental"])
        let page = try #require(document["page"] as? [String: Any])
        #expect(page["default_category"] as? String == "general")
    }

    /// Every row the page shows has exactly one group card, and a card names
    /// only rows the page shows.
    @Test func everyPageRowHasExactlyOneHome() throws {
        let document = try Self.document()
        let placed = try Self.categories(document).flatMap { category in
            (category["groups"] as? [[String: Any]] ?? []).flatMap { $0["rows"] as? [String] ?? [] }
        }
        let shown = SettingsSchema.all.filter(\.isShownOnSettingsPage).map(\.id)
        #expect(placed.count == Set(placed).count, "a row has two homes")
        #expect(Set(placed) == Set(shown), "homeless: \(Set(shown).subtracting(placed).sorted()); extra: \(Set(placed).subtracting(shown).sorted())")
    }

    /// Group cards come out in the order the layout lists them, rows of a
    /// schema group in schema order, and no card is empty.
    @Test func groupCardsKeepTheirOrderAndAreNeverEmpty() throws {
        let general = try #require(Self.categories(Self.document()).first)
        let groups = try #require(general["groups"] as? [[String: Any]])
        let keys = groups.compactMap { $0["key"] as? String }
        #expect(keys.first == "settings.group.window")
        #expect(keys.firstIndex(of: "settings.group.tabs")! < keys.firstIndex(of: "settings.group.chats")!)
        for group in groups { #expect(!(group["rows"] as? [String] ?? []).isEmpty, "\(group["key"] ?? "?") is empty") }
        let terminal = try #require(Self.categories(Self.document()).first { $0["id"] as? String == "terminal" })
        let behavior = try #require((terminal["groups"] as? [[String: Any]])?.first)
        #expect(behavior["key"] as? String == "terminal.0")
        #expect(behavior["rows"] as? [String] == ["newTerminal.opensWorkspace", "app.warnBeforeClosingTab"])
    }

    /// Every category and card title is a catalog key (the export refuses a
    /// key the catalog lacks); every old section id opens one category.
    @Test func titlesAreKeysAndEverySectionHasACategory() throws {
        let document = try Self.document()
        let categories = try Self.categories(document)
        for category in categories {
            #expect((category["title"] as? [String: Any])?["key"] is String, "\(category["id"] ?? "?") title has no key")
            #expect(category["symbol"] is String)
            for group in category["groups"] as? [[String: Any]] ?? [] {
                #expect((group["title"] as? [String: Any])?["key"] is String, "\(group["key"] ?? "?") title has no key")
            }
        }
        let aliases = categories.flatMap { $0["aliases"] as? [String] ?? [] }
        #expect(aliases.count == Set(aliases).count, "a section opens two categories")
        #expect(Set(aliases) == Set(SettingsSection.allCases.map(\.rawValue)))
    }
}
