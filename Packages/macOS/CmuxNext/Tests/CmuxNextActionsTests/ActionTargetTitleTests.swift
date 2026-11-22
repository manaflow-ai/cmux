import AppKit
import CmuxNextActions
import Testing

/// Target-aware context menu titles (PINNED-ITEMS-END-TO-END): the pin
/// toggle reads "Pin Tab" on an unpinned tab and "Unpin Tab" on a pinned
/// one, as in Chrome; the palette keeps the catalog title.
@MainActor
@Suite struct ActionTargetTitleTests {
    @Test func contextMenuUsesTheTitleForTheRightClickedTarget() throws {
        let registry = ActionRegistry.standard()
        registry.bind("palette.toggleTabPin", invoke: { _ in })
        ActionTargetTitles.set("palette.toggleTabPin", in: registry) { invocation in
            invocation.target?.id == "pinned" ? "Unpin Tab" : "Pin Tab"
        }
        let catalogTitle = try #require(registry.title(for: "palette.toggleTabPin"))
        func titles(_ id: String) -> [String] {
            registry.makeContextMenu(for: .tab, target: ActionTargetRef(kind: .tab, id: id)).items.map(\.title)
        }
        #expect(titles("pinned").contains("Unpin Tab"))
        #expect(titles("loose").contains("Pin Tab"))
        #expect(!titles("loose").contains(catalogTitle))
        #expect(registry.title(for: "palette.toggleTabPin") == catalogTitle)
    }

    @Test func nilKeepsTheCatalogTitle() throws {
        let registry = ActionRegistry.standard()
        registry.bind("palette.toggleTabPin", invoke: { _ in })
        ActionTargetTitles.set("palette.toggleTabPin", in: registry) { _ in nil }
        let catalogTitle = try #require(registry.title(for: "palette.toggleTabPin"))
        let menu = registry.makeContextMenu(for: .tab, target: ActionTargetRef(kind: .tab, id: "t"))
        #expect(menu.items.map(\.title).contains(catalogTitle))
    }
}
