import Foundation
import Testing

@testable import CmuxTextActions

/// Grouping of `type: "text"` actions into the right-click Snippets submenu:
/// categories become sub-submenus, uncategorised snippets sit at the top,
/// everything sorted for a stable menu.
struct CmuxSnippetMenuModelTests {
    private func entry(_ id: String, _ title: String, category: String? = nil, text: String = "x") throws -> CmuxSnippetMenuEntry {
        CmuxSnippetMenuEntry(
            actionID: id,
            title: title,
            category: category,
            payload: try #require(CmuxTextActionPayload(text: text, submit: false))
        )
    }

    @Test func emptyInputYieldsEmptyModel() throws {
        let model = CmuxSnippetMenuModel.build(from: [])
        #expect(model.isEmpty)
        #expect(model.uncategorized.isEmpty)
        #expect(model.categories.isEmpty)
    }

    @Test func groupsByCategoryAndSortsCategoriesAndItems() throws {
        let model = CmuxSnippetMenuModel.build(from: [
            try entry("b", "Zeta", category: "Git"),
            try entry("a", "Alpha", category: "Git"),
            try entry("c", "Lint", category: "Build"),
            try entry("d", "Loose one"),
            try entry("e", "Another loose")
        ])
        #expect(model.categories.map(\.name) == ["Build", "Git"])
        #expect(model.categories[1].items.map(\.title) == ["Alpha", "Zeta"])
        #expect(model.uncategorized.map(\.title) == ["Another loose", "Loose one"])
        #expect(!model.isEmpty)
    }

    @Test func blankOrWhitespaceCategoryCountsAsUncategorised() throws {
        let model = CmuxSnippetMenuModel.build(from: [
            try entry("a", "One", category: "   "),
            try entry("b", "Two", category: ""),
            try entry("c", "Three", category: " Ops ")
        ])
        #expect(model.uncategorized.map(\.title) == ["One", "Two"])
        #expect(model.categories.map(\.name) == ["Ops"])
    }

    @Test func categoryNamesMergeCaseInsensitivelyKeepingFirstSpelling() throws {
        let model = CmuxSnippetMenuModel.build(from: [
            try entry("a", "One", category: "git"),
            try entry("b", "Two", category: "Git")
        ])
        #expect(model.categories.count == 1)
        #expect(model.categories[0].name == "git")
        #expect(model.categories[0].items.map(\.title) == ["One", "Two"])
    }

    @Test func itemsKeepActionIDAndPayloadForDelivery() throws {
        let model = CmuxSnippetMenuModel.build(from: [
            try entry("review", "Review", category: "Prompts", text: "review this\nplease")
        ])
        let item = try #require(model.categories.first?.items.first)
        #expect(item.actionID == "review")
        #expect(item.payload.text == "review this\nplease")
        #expect(item.payload.submit == false)
    }
}
