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

    @Test func onlyTheLeadSectionIsUntitled() {
        let sections = SettingsPageLayout.sidebarSections
        #expect(sections.first?.title == nil)
        #expect(sections.dropFirst().allSatisfy { $0.title?.key != nil })
        #expect(sections.first?.categories.map(\.id) == ["general", "updates"])
    }

    @Test func theExportCarriesTheSidebarSections() throws {
        let page = SettingsSchemaExport().page { text, key in ["text": text, "key": key as Any] }
        let sections = try #require(page["sidebar_sections"] as? [[String: Any]])
        #expect(sections.map { $0["id"] as? String } == SettingsPageLayout.sidebarSections.map(\.id))
        let ids = sections.flatMap { $0["categories"] as? [String] ?? [] }
        let categories = try #require(page["categories"] as? [[String: Any]])
        #expect(ids == categories.compactMap { $0["id"] as? String })
    }
}
