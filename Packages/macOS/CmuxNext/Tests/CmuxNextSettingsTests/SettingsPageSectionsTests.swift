@testable import CmuxNextSettings
import Testing

/// The Settings page reads in sections (user 2026-10-30: "refactoring the settings page to look a
/// lot better with sections"): the sidebar groups categories under small headers, and no card is a
/// wall of rows a person has to scroll through to find one switch.
struct SettingsPageSectionsTests {
    private static let categories = SettingsPageLayout().categories()

    @Test func noCardHoldsMoreThanTheCap() {
        let long = Self.categories.flatMap { category in
            category.groups.filter { $0.rows.count > SettingsPageLayout.maxRowsPerCard }
                .map { "\(category.spec.id)/\($0.title.text): \($0.rows.count) rows" }
        }
        #expect(long.isEmpty, "split these cards: \(long)")
    }

    @Test func theSidebarSectionsHoldEveryCategoryOnceInOrder() {
        let listed = SettingsPageLayout.sidebarSections.flatMap { $0.categories.map(\.id) }
        #expect(listed == Self.categories.map(\.spec.id))
        #expect(Set(listed).count == listed.count)
        #expect(SettingsPageLayout.sidebarSections.allSatisfy { !$0.categories.isEmpty })
    }

    /// Six pages (one settings area, findings G6; Leo 2026-11-22: "ay, fuck it we ball"): every
    /// section is titled, and the sidebar draws each as one link that opens its first category.
    @Test func everySectionIsATitledPage() {
        let sections = SettingsPageLayout.sidebarSections
        #expect(sections.allSatisfy { $0.title?.key != nil })
        #expect(sections.map(\.id) == ["general", "appearance", "ai", "devices", "keyboard", "advanced"])
        #expect(sections.map { $0.categories.first?.id } == ["general", "appearance", "chat", "accounts", "keyboard", "advanced"])
    }

    @Test func theExportCarriesTheSidebarSections() throws {
        let page = SettingsSchemaExport().page { text, key in ["text": text, "key": key as Any] }
        let sections = try #require(page["sidebar_sections"] as? [[String: Any]])
        #expect(sections.map { $0["id"] as? String } == SettingsPageLayout.sidebarSections.map(\.id))
        let ids = sections.flatMap { $0["categories"] as? [String] ?? [] }
        let categories = try #require(page["categories"] as? [[String: Any]])
        #expect(ids == categories.compactMap { $0["id"] as? String })
    }

    /// One settings area (David Beyer, 2026-11-20: Settings felt overwhelming; Leo 2026-11-22: six
    /// pages): the sidebar's top level is six pages and no section is drawn closed. How cmux looks is
    /// one page, Appearance: there is no Personalization page.
    @Test func theTopLevelIsSixPages() throws {
        let page = SettingsSchemaExport().page { text, key in ["text": text, "key": key as Any] }
        let sections = try #require(page["sidebar_sections"] as? [[String: Any]])
        #expect(sections.count == 6, "the top level shows \(sections.count) pages")
        #expect(sections.allSatisfy { $0["collapsed"] as? Bool != true }, "no section is drawn closed")
        let ids = Self.categories.map(\.spec.id)
        #expect(!ids.contains("personalization"))
        let appearance = try #require(Self.categories.first { $0.spec.id == "appearance" })
        #expect(appearance.spec.lead == [.themeStudio, .backdrops, .density])
        #expect(appearance.spec.legacyIDs.contains("personalization"))
    }
}
